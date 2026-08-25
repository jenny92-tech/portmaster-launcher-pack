//! Capability-aware GitHub download transport.
//!
//! Route endpoints are deliberately kept out of result and error displays. A
//! caller can report route identifiers without leaking the registry into UI.

use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fmt;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::str::FromStr;
#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::ExclusiveFileLock;

const DEFAULT_BATCH_SIZE: usize = 5;
const MAX_BATCH_SIZE: usize = 10;
// Applied by `fetch` when the caller gives no explicit timeout. Without a
// deadline the per-attempt request runs with no global/read timeout, so one
// stalled connection would block its task (and any busy flag or lock the task
// holds) until the process is killed.
const DEFAULT_FETCH_TIMEOUT: Duration = Duration::from_secs(30 * 60);

// Runtime SOCKS fallback pool. When every bundled mirror route fails, the
// transport pulls a live proxy list (cached per process) and retries the
// download through those SOCKS proxies. The list lives on GitHub itself, so a
// single source would share the same outage as the mirrors it is meant to
// rescue; multiple CDN channels are tried in order and the first reachable
// source wins. Operators can override the whole set (one URL per line) with
// PORTKIT_GITHUB_SOCKS_FALLBACK_URL. Only the first MAX entries are used so a
// slow batch of dead proxies cannot consume the whole fetch deadline.
const SOCKS_FALLBACK_URLS: [&str; 3] = [
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/socks5/data.json",
    "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.json",
    "https://fastly.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.json",
];
const SOCKS_FALLBACK_TTL: Duration = Duration::from_secs(60 * 60);
const MAX_SOCKS_FALLBACK_CANDIDATES: usize = 50;

// GitHub acceleration mirror registry. Keep the bundled route data lightweight
// and non-plain so endpoint strings are not exposed by source/UI inspection.
// Proxy-list maintenance source: https://github.com/NapNeko/NapCat-Mac-Installer/blob/c30e49595d7ce1887edc9e8eb5d020b6846ef137/NapCatInstaller/Utils.swift#L174
const CUSTOM_ROUTES: &str = "7632298ac516bdb10737bfa1ee78d898c330af15e42eedb35f14059b3e259caf692976dc440f46a379d00aa26d36c584c80fbded0329f6adca0392cb9b76fb5bfa6de2921a1152db3c38d2a86c515e834a0a4ae229c064b11009c6dd8e58b0b4013ea84ccd00c185cc3cfb51";
const FULL_ROUTES: &str = "7435399fda45e4ec1c2da3adf463d4919e65f25d8827eab3431e11de62229dad2e386cdf5a185df467966fb37f4fd99fd103bce5506ee7bddd15c78ad120fb56a333e8944f10099a233af7a7702f48851c4919f772cc7eaa1c009b8ed57dbbaf073df51f915bc389dc7aed50a4258994524b4e86305399bf4cd74fc00d4d4dfc38da698a0f13c386d30cf9b3123fb049c60cd08f9639bb50170896945615118e3a5f9dc348d343c4115149f074dd98984216d89ad20aa9a72a5a9059d90cb690d46ee0794850c1904b0d158a383dacca51ce1a81551728f41afc8082525a8e9cdd4dbc472558dc488403d799ae76987a0e00d0c4081a538b4fcebfde47c34585181549cd60e48881041a9fd89e008a5f6d44cf59d64ac399362880760e0785d5045a54f011d9b3d450ce0287401ab0dc48e396e31819dd83fe21c8082051da43cd10c9e23f5e8f761404dc97400105f51dd1b5d4169c0f892660a6d00deb8bc31f07a767fd6b9b50610a815ace42a5ac315385684c0c918a19e57fe51dd2e38c0fd84cfc2432bcc309b6948e086ff97ff1639c05700ec551742abfbd7a41927b640b8eef67fa3dba5edab5df56d4a0af682bb9de11f995972560bb69e463f9532759d676647beba7205499611e49b2f06b8f6bfd01c9a29177a8abbd2736e4d8179a806d346dea39b2249f5c794eb22c222aafa435189b643191aae76bf16cb7569ab2ff72b1b9f0392dc4d006e0a46e763eb278f07b9346c93bbd633b3fb0b93352de0e37aae0f966e911e909c559e06aa0fba5322ab0d33691fe7f2d61";

fn read(encoded: &str) -> Option<String> {
    let mut output = Vec::with_capacity(encoded.len() / 2);
    let bytes = encoded.as_bytes();
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    const KEYS: [u8; 11] = [91, 37, 204, 113, 18, 167, 62, 209, 84, 9, 231];
    for (index, pair) in bytes.chunks_exact(2).enumerate() {
        let pair = std::str::from_utf8(pair).ok()?;
        let value = u8::from_str_radix(pair, 16).ok()?;
        output.push(value ^ KEYS[index % KEYS.len()] ^ (index.wrapping_mul(29) + 71) as u8);
    }
    String::from_utf8(output).ok()
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Capability {
    Release,
    Raw,
    Archive,
    Api,
    Gist,
    Clone,
}

impl Capability {
    pub const ALL: [Self; 6] = [
        Self::Release,
        Self::Raw,
        Self::Archive,
        Self::Api,
        Self::Gist,
        Self::Clone,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Release => "release",
            Self::Raw => "raw",
            Self::Archive => "archive",
            Self::Api => "api",
            Self::Gist => "gist",
            Self::Clone => "clone",
        }
    }
}

impl fmt::Display for Capability {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for Capability {
    type Err = GitHubError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|capability| capability.as_str() == value)
            .ok_or(GitHubError::UnknownCapability)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RouteFormatter {
    Direct,
    Full,
    Mirror,
    Jsdelivr,
    GitClone,
    /// Routes traffic through an explicit SOCKS forward proxy (`socks5://`,
    /// `socks5h://`, `socks4://`). The base is the proxy address; the source
    /// URL is left untouched. Only SOCKS proxies are accepted: TLS-wrapped
    /// proxies cannot be verified by rustls without disabling certificate
    /// checks for the target too, so `https://` forward proxies are rejected
    /// outright. TLS end-to-end guarantees stay enforced by the transport, so
    /// a malicious/intercepting proxy fails validation instead of decrypting.
    Forward,
}

#[derive(Clone, Debug)]
pub struct Route {
    id: String,
    formatter: RouteFormatter,
    capabilities: HashSet<Capability>,
    base: String,
}

impl Route {
    pub fn new(
        id: impl Into<String>,
        formatter: RouteFormatter,
        capabilities: impl IntoIterator<Item = Capability>,
        base: impl Into<String>,
    ) -> Result<Self, GitHubError> {
        let route = Self {
            id: id.into(),
            formatter,
            capabilities: capabilities.into_iter().collect(),
            base: base.into().trim_end_matches('/').to_owned(),
        };
        if !valid_route_id(&route.id)
            || route.capabilities.is_empty()
            || !valid_route_base(route.formatter, &route.base)
        {
            return Err(GitHubError::InvalidRoute);
        }
        Ok(route)
    }

    /// The forward-proxy address for `Forward` routes; `None` otherwise.
    fn forward_proxy(&self) -> Option<String> {
        (self.formatter == RouteFormatter::Forward).then(|| self.base.clone())
    }
}

#[derive(Clone, Debug)]
pub struct GitHubRegistry {
    routes: Vec<Route>,
}

impl Default for GitHubRegistry {
    fn default() -> Self {
        Self::bundled()
    }
}

impl GitHubRegistry {
    pub fn bundled() -> Self {
        let mut routes = Vec::new();
        for (index, row) in read(CUSTOM_ROUTES).unwrap_or_default().lines().enumerate() {
            let mut fields = row.splitn(3, '|');
            let format = fields.next().unwrap_or_default();
            let _label = fields.next().unwrap_or_default();
            let base = fields.next().unwrap_or_default();
            let (formatter, capabilities) = match format {
                "jsdelivr" => (RouteFormatter::Jsdelivr, vec![Capability::Raw]),
                "custom" => (
                    RouteFormatter::Mirror,
                    vec![Capability::Release, Capability::Raw, Capability::Archive],
                ),
                "full" | "github" => (
                    RouteFormatter::Full,
                    vec![
                        Capability::Release,
                        Capability::Raw,
                        Capability::Archive,
                        Capability::Clone,
                        Capability::Gist,
                    ],
                ),
                _ => continue,
            };
            if let Ok(route) = Route::new(format!("c{}", index + 1), formatter, capabilities, base)
            {
                routes.push(route);
            }
        }
        for (index, base) in read(FULL_ROUTES).unwrap_or_default().lines().enumerate() {
            if let Ok(route) = Route::new(
                format!("g{}", index + 1),
                RouteFormatter::Full,
                [
                    Capability::Release,
                    Capability::Raw,
                    Capability::Archive,
                    Capability::Clone,
                    Capability::Gist,
                ],
                base,
            ) {
                routes.push(route);
            }
        }
        routes.push(
            Route::new("origin", RouteFormatter::Direct, Capability::ALL, "")
                .expect("the built-in origin route is valid"),
        );
        Self { routes }
    }

    pub fn new(routes: Vec<Route>) -> Result<Self, GitHubError> {
        let mut ids = HashSet::new();
        if routes.is_empty() || routes.iter().any(|route| !ids.insert(route.id.clone())) {
            return Err(GitHubError::InvalidRoute);
        }
        Ok(Self { routes })
    }

    /// Uses an operator/test route override when present, otherwise the
    /// bundled registry. Invalid override rows are ignored and an unusable
    /// override falls back to the bundled routes.
    pub fn configured() -> Self {
        let Ok(raw) = std::env::var("PORTKIT_GITHUB_ROUTES") else {
            return Self::bundled();
        };
        let mut routes = Vec::new();
        for (index, base) in raw
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .enumerate()
        {
            let (formatter, capabilities): (_, Vec<Capability>) = if base.starts_with("socks5://")
                || base.starts_with("socks5h://")
                || base.starts_with("socks4://")
            {
                (
                    RouteFormatter::Forward,
                    vec![
                        Capability::Release,
                        Capability::Raw,
                        Capability::Archive,
                        Capability::Gist,
                    ],
                )
            } else {
                (
                    RouteFormatter::Full,
                    vec![
                        Capability::Release,
                        Capability::Raw,
                        Capability::Archive,
                        Capability::Clone,
                        Capability::Gist,
                    ],
                )
            };
            if let Ok(route) = Route::new(format!("r{}", index + 1), formatter, capabilities, base)
            {
                routes.push(route);
            }
        }
        Self::new(routes).unwrap_or_else(|_| Self::bundled())
    }

    pub fn candidate_route_ids(
        &self,
        capability: Capability,
        source: &str,
    ) -> Result<Vec<String>, GitHubError> {
        Ok(self
            .candidates(capability, source)?
            .into_iter()
            .map(|candidate| candidate.route_id)
            .collect())
    }

    pub fn candidates(
        &self,
        capability: Capability,
        source: &str,
    ) -> Result<Vec<GitHubCandidate>, GitHubError> {
        validate_source(capability, source)?;
        let candidates = self
            .routes
            .iter()
            .filter(|route| route.capabilities.contains(&capability))
            .filter_map(|route| {
                format_endpoint(route, capability, source).map(|endpoint| GitHubCandidate {
                    route_id: route.id.clone(),
                    endpoint,
                    proxy: route.forward_proxy(),
                })
            })
            .collect::<Vec<_>>();
        if candidates.is_empty() {
            Err(GitHubError::NoCandidates)
        } else {
            Ok(candidates)
        }
    }
}

#[derive(Debug)]
pub struct GitHubTransport {
    registry: GitHubRegistry,
    batch_size: usize,
    socks_fallback_urls: Vec<String>,
}

/// Streamed progress during a file fetch. `received`/`total` are bytes; `total`
/// is 0 when the server provides no Content-Length. Called from the transfer
/// thread; implementations must be cheap and non-blocking.
pub trait Progress {
    /// Starts a new route/attempt. The default keeps simple callbacks source-compatible.
    fn begin(&self, received: u64, total: u64) -> io::Result<()> {
        self.update(received, total)
    }

    fn update(&self, received: u64, total: u64) -> io::Result<()>;

    fn finish(&self, received: u64, total: u64) -> io::Result<()> {
        self.update(received, total)
    }
}

impl Default for GitHubTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl GitHubTransport {
    pub fn new() -> Self {
        Self::with_registry(GitHubRegistry::configured())
    }

    pub fn with_registry(registry: GitHubRegistry) -> Self {
        let socks_fallback_urls = match std::env::var("PORTKIT_GITHUB_SOCKS_FALLBACK_URL") {
            Ok(raw) => raw
                .lines()
                .map(str::trim)
                .filter(|url| !url.is_empty())
                .map(str::to_owned)
                .collect::<Vec<_>>(),
            Err(_) => SOCKS_FALLBACK_URLS
                .iter()
                .map(|url| (*url).to_owned())
                .collect(),
        };
        Self {
            registry,
            batch_size: DEFAULT_BATCH_SIZE,
            socks_fallback_urls,
        }
    }

    pub fn set_batch_size(&mut self, batch_size: usize) -> Result<(), GitHubError> {
        if !(1..=MAX_BATCH_SIZE).contains(&batch_size) {
            return Err(GitHubError::InvalidBatchSize);
        }
        self.batch_size = batch_size;
        Ok(())
    }

    pub fn candidate_route_ids(
        &self,
        capability: Capability,
        source: &str,
    ) -> Result<Vec<String>, GitHubError> {
        self.registry.candidate_route_ids(capability, source)
    }

    pub fn fetch<F>(
        &self,
        capability: Capability,
        source: &str,
        output: &Path,
        validator: F,
        progress: Option<&dyn Progress>,
        max_bytes: Option<u64>,
    ) -> Result<FetchOutcome, GitHubError>
    where
        F: Fn(&Path) -> bool,
    {
        self.fetch_with_timeout(
            capability,
            source,
            output,
            validator,
            progress,
            max_bytes,
            DEFAULT_FETCH_TIMEOUT,
        )
    }

    /// Fetches a file while bounding probing, retries, and transfer by one
    /// shared wall-clock deadline.
    #[allow(clippy::too_many_arguments)]
    pub fn fetch_with_timeout<F>(
        &self,
        capability: Capability,
        source: &str,
        output: &Path,
        validator: F,
        progress: Option<&dyn Progress>,
        max_bytes: Option<u64>,
        timeout: Duration,
    ) -> Result<FetchOutcome, GitHubError>
    where
        F: Fn(&Path) -> bool,
    {
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or(GitHubError::DeadlineExceeded)?;
        self.fetch_inner(
            capability,
            source,
            output,
            validator,
            progress,
            max_bytes,
            Some(deadline),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn fetch_inner<F>(
        &self,
        capability: Capability,
        source: &str,
        output: &Path,
        validator: F,
        progress: Option<&dyn Progress>,
        max_bytes: Option<u64>,
        deadline: Option<Instant>,
    ) -> Result<FetchOutcome, GitHubError>
    where
        F: Fn(&Path) -> bool,
    {
        if capability == Capability::Clone {
            return Err(GitHubError::UnsupportedFileFetch { capability });
        }
        eprintln!("[GH] fetch cap={capability:?} source={source}");
        let candidates = match self.registry.candidates(capability, source) {
            Ok(candidates) => candidates,
            // An empty registry for this capability must still fall through to
            // the dynamic SOCKS pool instead of failing immediately.
            Err(GitHubError::NoCandidates) => Vec::new(),
            Err(error) => return Err(error),
        };
        let mut validation_failed = false;
        match self.attempt_candidates(
            candidates,
            capability,
            output,
            &validator,
            progress,
            max_bytes,
            deadline,
            &mut validation_failed,
            true,
        ) {
            Ok(outcome) => return Ok(outcome),
            Err(GitHubError::Exhausted { .. }) => {}
            Err(error) => return Err(error),
        }
        // Every bundled route failed. Pull the dynamic SOCKS pool once and
        // retry through those forward proxies; a fresh list (or an empty one)
        // fails fast and keeps the original exhaustion result.
        let fallback = self.socks_fallback_candidates(capability, source, deadline)?;
        eprintln!(
            "[GH] bundled routes exhausted; socks fallback candidates={}",
            fallback.len()
        );
        if !fallback.is_empty() {
            match self.attempt_candidates(
                fallback,
                capability,
                output,
                &validator,
                progress,
                max_bytes,
                deadline,
                &mut validation_failed,
                false,
            ) {
                Ok(outcome) => return Ok(outcome),
                Err(GitHubError::Exhausted { .. }) => {}
                Err(error) => return Err(error),
            }
        }
        eprintln!("[GH] all routes exhausted (validation_failed={validation_failed})");
        Err(GitHubError::Exhausted { validation_failed })
    }

    /// Probes and transfers one batch plan. `remember_preferred` is false for
    /// dynamic SOCKS candidates: a one-shot proxy that happened to work for one
    /// file must not shadow the bundled mirrors for later fetches.
    #[allow(clippy::too_many_arguments)]
    fn attempt_candidates<F>(
        &self,
        mut candidates: Vec<GitHubCandidate>,
        capability: Capability,
        output: &Path,
        validator: &F,
        progress: Option<&dyn Progress>,
        max_bytes: Option<u64>,
        deadline: Option<Instant>,
        validation_failed: &mut bool,
        remember_preferred: bool,
    ) -> Result<FetchOutcome, GitHubError>
    where
        F: Fn(&Path) -> bool,
    {
        let preferred = self.preferred_route(capability);
        if let Some(index) = preferred.as_ref().and_then(|id| {
            candidates
                .iter()
                .position(|candidate| &candidate.route_id == id)
        }) {
            candidates.swap(0, index);
        } else if preferred.is_some() {
            self.clear_preferred(capability);
        }

        for batch in candidates.chunks(self.batch_size) {
            remaining(deadline)?;
            eprintln!("[GH] probing batch of {} candidates", batch.len());
            let mut responsive = self.probe_batch(batch, deadline)?;
            eprintln!(
                "[GH] batch responsive={} ({} total)",
                responsive.len(),
                candidates.len()
            );
            if let Some(id) = self.preferred_route(capability) {
                if let Some(index) = responsive
                    .iter()
                    .position(|candidate| candidate.route_id == id)
                {
                    responsive.swap(0, index);
                } else if batch.iter().any(|candidate| candidate.route_id == id) {
                    self.clear_preferred(capability);
                }
            }
            for candidate in responsive {
                remaining(deadline)?;
                eprintln!(
                    "[GH] transfer try route={} endpoint={}",
                    candidate.route_id, candidate.endpoint
                );
                match self.transfer(&candidate, output, validator, progress, max_bytes, deadline) {
                    Ok(()) => {
                        eprintln!("[GH] transfer OK route={}", candidate.route_id);
                        if remember_preferred {
                            self.set_preferred(capability, &candidate.route_id);
                        }
                        return Ok(FetchOutcome {
                            route_id: candidate.route_id,
                        });
                    }
                    Err(AttemptError::Validation) => {
                        eprintln!(
                            "[GH] transfer validation-failed route={}",
                            candidate.route_id
                        );
                        *validation_failed = true;
                        self.clear_if_preferred(capability, &candidate.route_id);
                    }
                    Err(AttemptError::Transfer) => {
                        eprintln!("[GH] transfer failed route={}", candidate.route_id);
                        self.clear_if_preferred(capability, &candidate.route_id);
                    }
                    Err(AttemptError::Deadline) => return Err(GitHubError::DeadlineExceeded),
                    Err(AttemptError::Io(error)) => return Err(GitHubError::Io(error)),
                }
            }
        }
        Err(GitHubError::Exhausted {
            validation_failed: *validation_failed,
        })
    }

    /// Builds forward-proxy candidates from the cached dynamic SOCKS list.
    /// Failures to fetch or parse the list are silent: the fallback is a
    /// best-effort layer and must never turn a plain exhaustion into a hard
    /// error.
    fn socks_fallback_candidates(
        &self,
        capability: Capability,
        source: &str,
        deadline: Option<Instant>,
    ) -> Result<Vec<GitHubCandidate>, GitHubError> {
        if self.socks_fallback_urls.is_empty() {
            return Ok(Vec::new());
        }
        if !matches!(
            capability,
            Capability::Release | Capability::Raw | Capability::Archive | Capability::Gist
        ) {
            return Ok(Vec::new());
        }
        let proxies = cached_socks_proxies(&self.socks_fallback_urls, deadline);
        Ok(proxies
            .into_iter()
            .enumerate()
            .map(|(index, proxy)| GitHubCandidate {
                route_id: format!("socks{}", index + 1),
                endpoint: source.to_owned(),
                proxy: Some(proxy),
            })
            .collect())
    }

    fn probe_batch(
        &self,
        batch: &[GitHubCandidate],
        deadline: Option<Instant>,
    ) -> Result<Vec<GitHubCandidate>, GitHubError> {
        let responsive = std::thread::scope(|scope| {
            let (sender, receiver) = std::sync::mpsc::channel();
            for candidate in batch.iter().cloned() {
                let sender = sender.clone();
                scope.spawn(move || {
                    if self.probe(&candidate, deadline) {
                        let _ = sender.send(candidate);
                    }
                });
            }
            drop(sender);
            receiver.into_iter().collect()
        });
        remaining(deadline)?;
        Ok(responsive)
    }

    fn probe(&self, candidate: &GitHubCandidate, deadline: Option<Instant>) -> bool {
        let Ok(timeout) = remaining(deadline) else {
            return false;
        };
        let mut config = ureq::config::Config::builder()
            .timeout_connect(Some(Duration::from_secs(3)))
            .timeout_global(Some(timeout.min(Duration::from_secs(5))));
        if let Some(proxy) = candidate
            .proxy
            .as_deref()
            .and_then(|address| ureq::Proxy::new(address).ok())
        {
            config = config.proxy(Some(proxy));
        }
        let agent = ureq::Agent::new_with_config(config.build());
        // A 2xx response (including 206 to the Range probe) means the route is
        // reachable; whether it actually delivers usable content is confirmed
        // by the transfer validator. Non-2xx or transport errors skip it.
        let result = agent
            .get(&candidate.endpoint)
            .header("Range", "bytes=0-15")
            .call();
        let ok = result.is_ok();
        eprintln!(
            "[GH] probe route={} {} {}",
            candidate.route_id,
            if ok { "ok" } else { "FAIL" },
            result
                .map(|r| r.status().as_u16())
                .map_or(String::new(), |c| format!("code={c}"))
        );
        ok
    }

    fn transfer<F>(
        &self,
        candidate: &GitHubCandidate,
        output: &Path,
        validator: &F,
        progress: Option<&dyn Progress>,
        max_bytes: Option<u64>,
        deadline: Option<Instant>,
    ) -> Result<(), AttemptError>
    where
        F: Fn(&Path) -> bool,
    {
        let part = suffixed_path(output, ".part");
        let sidecar = suffixed_path(output, ".part.route");
        let _lock = TransferLock::acquire(output).map_err(AttemptError::Io)?;
        prepare_partial(&part, &sidecar, &candidate.endpoint).map_err(AttemptError::Io)?;

        if let Err(error) = self.run_transfer(
            &candidate.endpoint,
            candidate.proxy.as_deref(),
            &part,
            &sidecar,
            progress,
            max_bytes,
            deadline,
        ) {
            // Keep a non-empty partial so a same-route retry can resume; clear
            // an empty one so the next attempt starts clean.
            if !part.metadata().is_ok_and(|metadata| metadata.len() > 0) {
                remove_if_exists(&part).map_err(AttemptError::Io)?;
                remove_if_exists(&sidecar).map_err(AttemptError::Io)?;
            }
            return Err(error);
        }
        if !validator(&part) {
            remove_if_exists(&part).map_err(AttemptError::Io)?;
            remove_if_exists(&sidecar).map_err(AttemptError::Io)?;
            return Err(AttemptError::Validation);
        }
        fs::rename(&part, output).map_err(AttemptError::Io)?;
        remove_if_exists(&sidecar).map_err(AttemptError::Io)?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn run_transfer(
        &self,
        endpoint: &str,
        proxy: Option<&str>,
        part: &Path,
        sidecar: &Path,
        progress: Option<&dyn Progress>,
        max_bytes: Option<u64>,
        deadline: Option<Instant>,
    ) -> Result<(), AttemptError> {
        // Mirror curl's `--retry 2 --retry-delay 1`: retry transient failures
        // twice before giving up.
        for attempt in 0..=2 {
            remaining(deadline).map_err(|_| AttemptError::Deadline)?;
            if attempt > 0 {
                if remaining(deadline).map_err(|_| AttemptError::Deadline)?
                    <= Duration::from_secs(1)
                {
                    return Err(AttemptError::Deadline);
                }
                std::thread::sleep(Duration::from_secs(1));
            }
            match self.single_transfer(
                endpoint, proxy, part, sidecar, progress, max_bytes, deadline,
            ) {
                Ok(()) => return Ok(()),
                Err(AttemptError::Io(error)) => return Err(AttemptError::Io(error)),
                Err(AttemptError::Validation) => return Err(AttemptError::Validation),
                Err(AttemptError::Deadline) => return Err(AttemptError::Deadline),
                Err(AttemptError::Transfer) => continue,
            }
        }
        Err(AttemptError::Transfer)
    }

    #[allow(clippy::too_many_arguments)]
    fn single_transfer(
        &self,
        endpoint: &str,
        proxy: Option<&str>,
        part: &Path,
        sidecar: &Path,
        progress: Option<&dyn Progress>,
        max_bytes: Option<u64>,
        deadline: Option<Instant>,
    ) -> Result<(), AttemptError> {
        let mut config =
            ureq::config::Config::builder().timeout_connect(Some(Duration::from_secs(8)));
        if deadline.is_some() {
            config = config.timeout_global(Some(
                remaining(deadline).map_err(|_| AttemptError::Deadline)?,
            ));
        }
        if let Some(proxy) = proxy.and_then(|address| ureq::Proxy::new(address).ok()) {
            config = config.proxy(Some(proxy));
        }
        let agent = ureq::Agent::new_with_config(config.build());
        reject_symlink(part).map_err(AttemptError::Io)?;
        let mut existing_len = fs::metadata(part)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        let resume_validator = partial_validator(sidecar).map_err(AttemptError::Io)?;
        let want_resume = existing_len > 0 && resume_validator.is_some();
        let mut request = agent.get(endpoint);
        if want_resume {
            request = request
                .header("Range", &format!("bytes={existing_len}-"))
                .header("If-Range", resume_validator.as_deref().unwrap_or_default());
        }
        let mut response = request.call().map_err(|_| AttemptError::Transfer)?;
        // A server that ignores Range answers 200 with full content; truncate and
        // rewrite from the start instead of appending (curl's exit-33 restart).
        let mut status = response.status();
        let mut append = want_resume && status == 206;
        let mut range_total = append.then(|| {
            parse_content_range(
                response
                    .headers()
                    .get("Content-Range")
                    .and_then(|value| value.to_str().ok()),
                existing_len,
                max_bytes,
            )
        });
        if append && range_total.flatten().is_none() {
            response = agent
                .get(endpoint)
                .call()
                .map_err(|_| AttemptError::Transfer)?;
            status = response.status();
            append = false;
            range_total = None;
            existing_len = 0;
        }
        if status == 206 && !append {
            return Err(AttemptError::Transfer);
        }
        let content_length = response
            .headers()
            .get("Content-Length")
            .and_then(|value| value.to_str().ok())
            .and_then(|text| text.parse::<u64>().ok());
        let total = range_total
            .flatten()
            .or_else(|| {
                content_length
                    .and_then(|length| length.checked_add(if append { existing_len } else { 0 }))
            })
            .unwrap_or(0);
        if append
            && content_length
                .and_then(|length| length.checked_add(existing_len))
                .is_some_and(|length| length != total)
        {
            return Err(AttemptError::Transfer);
        }
        if max_bytes.is_some_and(|max| total > max || existing_len > max) {
            return Err(AttemptError::Validation);
        }
        let validator = response
            .headers()
            .get("ETag")
            .and_then(|value| value.to_str().ok())
            .filter(|value| !value.starts_with("W/"))
            .or_else(|| {
                response
                    .headers()
                    .get("Last-Modified")
                    .and_then(|value| value.to_str().ok())
            })
            .filter(|value| !value.contains(['\r', '\n']))
            .map(str::to_owned);
        write_partial_state(sidecar, endpoint, validator.as_deref()).map_err(AttemptError::Io)?;
        let mut options = fs::OpenOptions::new();
        options.write(true).append(append).truncate(!append);
        if append {
            options.create(false);
        } else {
            options.create(true);
        }
        let mut file = options.open(part).map_err(AttemptError::Io)?;
        let mut reader = response.into_body().into_reader();
        let mut buffer = [0u8; 65536];
        let mut written = if append { existing_len } else { 0 };
        if let Some(progress) = progress {
            progress.begin(written, total).map_err(AttemptError::Io)?;
        }
        loop {
            let n = reader
                .read(&mut buffer)
                .map_err(|_| AttemptError::Transfer)?;
            if n == 0 {
                break;
            }
            file.write_all(&buffer[..n])
                .map_err(|_| AttemptError::Transfer)?;
            written = written
                .checked_add(n as u64)
                .ok_or(AttemptError::Validation)?;
            if max_bytes.is_some_and(|max| written > max) {
                return Err(AttemptError::Validation);
            }
            if let Some(progress) = progress.filter(|_| total == 0 || written != total) {
                progress.update(written, total).map_err(AttemptError::Io)?;
            }
        }
        if content_length
            .is_some_and(|length| written - if append { existing_len } else { 0 } != length)
            || (append && total != 0 && written != total)
        {
            return Err(AttemptError::Transfer);
        }
        if let Some(progress) = progress {
            progress.finish(written, total).map_err(AttemptError::Io)?;
        }
        Ok(())
    }

    fn preferred_route(&self, capability: Capability) -> Option<String> {
        preferred_routes()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&capability)
            .cloned()
    }

    fn set_preferred(&self, capability: Capability, route_id: &str) {
        preferred_routes()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(capability, route_id.to_owned());
    }

    fn clear_preferred(&self, capability: Capability) {
        preferred_routes()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&capability);
    }

    fn clear_if_preferred(&self, capability: Capability, route_id: &str) {
        let mut preferred = preferred_routes()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if preferred.get(&capability).is_some_and(|id| id == route_id) {
            preferred.remove(&capability);
        }
    }
}

fn preferred_routes() -> &'static Mutex<HashMap<Capability, String>> {
    static PREFERRED: OnceLock<Mutex<HashMap<Capability, String>>> = OnceLock::new();
    PREFERRED.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FetchOutcome {
    route_id: String,
}

impl FetchOutcome {
    pub fn route_id(&self) -> &str {
        &self.route_id
    }
}

#[derive(Debug)]
pub enum GitHubError {
    UnknownCapability,
    InvalidCapabilitySource { capability: Capability },
    UnsupportedFileFetch { capability: Capability },
    InvalidRoute,
    InvalidBatchSize,
    NoCandidates,
    DeadlineExceeded,
    Exhausted { validation_failed: bool },
    Io(io::Error),
}

impl fmt::Display for GitHubError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownCapability => formatter.write_str("unknown GitHub capability"),
            Self::InvalidCapabilitySource { capability } => {
                write!(
                    formatter,
                    "source does not match the {capability} capability"
                )
            }
            Self::UnsupportedFileFetch { capability } => {
                write!(
                    formatter,
                    "the {capability} capability cannot be fetched as a file"
                )
            }
            Self::InvalidRoute => formatter.write_str("invalid GitHub transport route"),
            Self::InvalidBatchSize => {
                write!(
                    formatter,
                    "probe batch size must be between 1 and {MAX_BATCH_SIZE}"
                )
            }
            Self::NoCandidates => formatter.write_str("no GitHub transport routes are available"),
            Self::DeadlineExceeded => formatter.write_str("GitHub transport deadline exceeded"),
            Self::Exhausted { validation_failed } if *validation_failed => {
                formatter.write_str("all GitHub transport routes failed transfer or validation")
            }
            Self::Exhausted { .. } => formatter.write_str("all GitHub transport routes failed"),
            Self::Io(error) => write!(formatter, "GitHub transport I/O error: {error}"),
        }
    }
}

impl std::error::Error for GitHubError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for GitHubError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Clone)]
pub struct GitHubCandidate {
    route_id: String,
    endpoint: String,
    proxy: Option<String>,
}

impl GitHubCandidate {
    pub fn route_id(&self) -> &str {
        &self.route_id
    }

    /// Returns the formatted endpoint for programmatic transport use.
    ///
    /// User interfaces should report [`Self::route_id`] instead.
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }
}

impl fmt::Debug for GitHubCandidate {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GitHubCandidate")
            .field("route_id", &self.route_id)
            .field("endpoint", &"<redacted>")
            .finish()
    }
}

#[derive(Debug)]
enum AttemptError {
    Transfer,
    Validation,
    Deadline,
    Io(io::Error),
}

fn remaining(deadline: Option<Instant>) -> Result<Duration, GitHubError> {
    match deadline {
        Some(deadline) => deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .ok_or(GitHubError::DeadlineExceeded),
        None => Ok(Duration::MAX),
    }
}

fn validate_source(capability: Capability, source: &str) -> Result<(), GitHubError> {
    let valid = !source.is_empty()
        && !source.chars().any(char::is_whitespace)
        && match capability {
            Capability::Release => github_repo_rest(source).is_some_and(|(_, _, rest)| {
                rest.starts_with("releases/download/")
                    || rest.starts_with("releases/latest/download/")
            }),
            Capability::Raw => {
                host_path(source, "https://raw.githubusercontent.com/")
                    .is_some_and(has_four_path_parts)
                    || github_repo_rest(source).is_some_and(|(_, _, rest)| {
                        rest.strip_prefix("raw/").is_some_and(has_two_path_parts)
                    })
            }
            Capability::Archive => {
                github_repo_rest(source).is_some_and(|(_, _, rest)| rest.starts_with("archive/"))
                    || host_path(source, "https://codeload.github.com/")
                        .is_some_and(has_three_path_parts)
            }
            Capability::Api => host_path(source, "https://api.github.com/").is_some(),
            Capability::Gist => {
                host_path(source, "https://gist.githubusercontent.com/").is_some()
                    || host_path(source, "https://gist.github.com/").is_some()
            }
            Capability::Clone => github_repo_rest(source).is_some_and(|(owner, repo, rest)| {
                !source.ends_with('/')
                    && rest.is_empty()
                    && valid_segment(owner)
                    && valid_segment(repo.strip_suffix(".git").unwrap_or(repo))
            }),
        };
    if valid {
        Ok(())
    } else {
        Err(GitHubError::InvalidCapabilitySource { capability })
    }
}

fn github_repo_rest(source: &str) -> Option<(&str, &str, &str)> {
    let path = host_path(source, "https://github.com/")?;
    let mut parts = path.splitn(3, '/');
    let owner = parts.next()?;
    let repo = parts.next()?;
    let rest = parts.next().unwrap_or("");
    (valid_segment(owner) && valid_segment(repo)).then_some((owner, repo, rest))
}

fn host_path<'a>(source: &'a str, prefix: &str) -> Option<&'a str> {
    let path = source.strip_prefix(prefix)?;
    (!path.is_empty() && !path.starts_with('/')).then_some(path)
}

fn valid_segment(segment: &str) -> bool {
    !segment.is_empty() && !matches!(segment, "." | "..") && !segment.contains(['/', '?', '#', ':'])
}

fn has_two_path_parts(path: &str) -> bool {
    path.split('/').filter(|part| !part.is_empty()).count() >= 2
}

fn has_three_path_parts(path: &str) -> bool {
    path.split('/').filter(|part| !part.is_empty()).count() >= 3
}

fn has_four_path_parts(path: &str) -> bool {
    path.split('/').filter(|part| !part.is_empty()).count() >= 4
}

fn format_endpoint(route: &Route, capability: Capability, source: &str) -> Option<String> {
    match route.formatter {
        RouteFormatter::Direct | RouteFormatter::Forward => Some(source.to_owned()),
        RouteFormatter::Full => Some(format!("{}/{}", route.base, source)),
        RouteFormatter::Mirror => {
            let path = if capability == Capability::Raw {
                raw_github_path(source)?
            } else {
                source.strip_prefix("https://github.com/")?.to_owned()
            };
            Some(format!("{}/{path}", route.base))
        }
        RouteFormatter::Jsdelivr if capability == Capability::Raw => {
            Some(format!("{}/{}", route.base, raw_jsdelivr_path(source)?))
        }
        RouteFormatter::GitClone if capability == Capability::Clone => Some(format!(
            "{}/{}",
            route.base,
            source.strip_prefix("https://")?
        )),
        _ => None,
    }
}

fn raw_github_path(source: &str) -> Option<String> {
    if let Some(path) = source.strip_prefix("https://github.com/") {
        return Some(path.to_owned());
    }
    let path = source.strip_prefix("https://raw.githubusercontent.com/")?;
    let mut parts = path.splitn(3, '/');
    Some(format!(
        "{}/{}/raw/{}",
        parts.next()?,
        parts.next()?,
        parts.next()?
    ))
}

fn raw_jsdelivr_path(source: &str) -> Option<String> {
    let path = if let Some(path) = source.strip_prefix("https://raw.githubusercontent.com/") {
        path
    } else {
        source.strip_prefix("https://github.com/")?
    };
    let mut parts = path.splitn(3, '/');
    let owner = parts.next()?;
    let repo = parts.next()?;
    let rest = parts.next()?;
    let rest = rest.strip_prefix("raw/").unwrap_or(rest);
    Some(format!("{owner}/{repo}@{rest}"))
}

fn valid_route_id(id: &str) -> bool {
    !id.is_empty()
        && !matches!(id, "." | "..")
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn valid_route_base(formatter: RouteFormatter, base: &str) -> bool {
    if formatter == RouteFormatter::Direct {
        base.is_empty()
    } else if formatter == RouteFormatter::Forward {
        valid_forward_base(base)
    } else {
        let https = base.strip_prefix("https://");
        let http = base.strip_prefix("http://");
        let Some(rest) = https.or(http) else {
            return false;
        };
        let authority = rest.split('/').next().unwrap_or_default();
        let Some(host) = authority_host(authority) else {
            return false;
        };
        let loopback = matches!(host, "127.0.0.1" | "localhost" | "::1");
        !authority.is_empty()
            && !base.chars().any(char::is_whitespace)
            && (https.is_some() || loopback)
    }
}

/// A forward-proxy base is an explicit SOCKS address (`socks4://`, `socks5://`,
/// `socks5h://`) with a host and a port. HTTP and TLS-wrapped proxies are
/// rejected: plaintext HTTP proxies cannot be verified, and TLS-wrapped
/// proxies cannot be verified by rustls without also disabling target
/// certificate checks. SOCKS tunnels keep TLS strictly end-to-end.
fn valid_forward_base(base: &str) -> bool {
    if base.chars().any(char::is_whitespace) {
        return false;
    }
    let rest = base
        .strip_prefix("socks5://")
        .or_else(|| base.strip_prefix("socks5h://"))
        .or_else(|| base.strip_prefix("socks4://"));
    let Some(rest) = rest else {
        return false;
    };
    let authority = rest.split('/').next().unwrap_or_default();
    if authority.is_empty() || !authority.contains(':') {
        return false;
    }
    authority_host(authority).is_some()
}

fn authority_host(authority: &str) -> Option<&str> {
    if authority.contains('@') {
        return None;
    }
    if let Some(bracketed) = authority.strip_prefix('[') {
        let (host, suffix) = bracketed.split_once(']')?;
        if !suffix.is_empty()
            && !suffix.strip_prefix(':').is_some_and(|port| {
                !port.is_empty() && port.bytes().all(|byte| byte.is_ascii_digit())
            })
        {
            return None;
        }
        return Some(host);
    }
    match authority.split_once(':') {
        Some((host, port))
            if !host.is_empty()
                && !port.is_empty()
                && !port.contains(':')
                && port.bytes().all(|byte| byte.is_ascii_digit()) =>
        {
            Some(host)
        }
        Some(_) => None,
        None if !authority.is_empty() => Some(authority),
        None => None,
    }
}

fn suffixed_path(path: &Path, suffix: &str) -> PathBuf {
    let mut value: OsString = path.as_os_str().to_owned();
    value.push(suffix);
    PathBuf::from(value)
}

fn prepare_partial(part: &Path, sidecar: &Path, endpoint: &str) -> io::Result<()> {
    reject_symlink(part)?;
    reject_symlink(sidecar)?;
    let fingerprint = route_fingerprint(endpoint);
    let matches = fs::read_to_string(sidecar)
        .ok()
        .and_then(|stored| stored.lines().next().map(str::to_owned))
        .is_some_and(|stored| stored == fingerprint);
    if !matches {
        remove_if_exists(part)?;
        remove_if_exists(sidecar)?;
        write_partial_state(sidecar, endpoint, None)?;
    }
    Ok(())
}

fn write_partial_state(sidecar: &Path, endpoint: &str, validator: Option<&str>) -> io::Result<()> {
    reject_symlink(sidecar)?;
    let temp = suffixed_path(sidecar, &format!(".tmp.{}", std::process::id()));
    reject_symlink(&temp)?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)?;
    writeln!(file, "{}", route_fingerprint(endpoint))?;
    if let Some(validator) = validator {
        writeln!(file, "{validator}")?;
    }
    file.sync_all()?;
    drop(file);
    reject_symlink(sidecar)?;
    fs::rename(&temp, sidecar).inspect_err(|_| {
        let _ = fs::remove_file(&temp);
    })
}

fn partial_validator(sidecar: &Path) -> io::Result<Option<String>> {
    reject_symlink(sidecar)?;
    Ok(fs::read_to_string(sidecar)
        .ok()
        .and_then(|stored| stored.lines().nth(1).map(str::to_owned))
        .filter(|value| !value.is_empty()))
}

fn parse_content_range(
    value: Option<&str>,
    expected_start: u64,
    max_bytes: Option<u64>,
) -> Option<u64> {
    let value = value.and_then(|value| value.strip_prefix("bytes "))?;
    let (range, total) = value.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    let (Ok(start), Ok(end), Ok(total)) = (
        start.parse::<u64>(),
        end.parse::<u64>(),
        total.parse::<u64>(),
    ) else {
        return None;
    };
    (start == expected_start
        && end >= start
        && total > end
        && end.checked_add(1) == Some(total)
        && !max_bytes.is_some_and(|max| total > max))
    .then_some(total)
}

fn reject_symlink(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("temporary path is a symlink: {}", path.display()),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[derive(Debug)]
struct TransferLock {
    _lock: ExclusiveFileLock,
}

impl TransferLock {
    fn acquire(output: &Path) -> io::Result<Self> {
        let path = suffixed_path(output, ".part.lock");
        ExclusiveFileLock::try_acquire(&path)
            .map(|lock| Self { _lock: lock })
            .map_err(|error| {
                if error.kind() == io::ErrorKind::WouldBlock {
                    io::Error::new(io::ErrorKind::WouldBlock, "download is already in progress")
                } else {
                    error
                }
            })
    }
}

type SocksCache = OnceLock<Mutex<HashMap<String, (Instant, Vec<String>)>>>;

/// Returns the first cached or freshly fetched SOCKS list across all fallback
/// sources. Sources are tried in order so a dead GitHub channel does not block
/// a reachable CDN channel.
fn cached_socks_proxies(urls: &[String], deadline: Option<Instant>) -> Vec<String> {
    for url in urls {
        if let Some(list) = cached_socks_proxies_from(url, deadline) {
            return list;
        }
    }
    Vec::new()
}

fn cached_socks_proxies_from(url: &str, deadline: Option<Instant>) -> Option<Vec<String>> {
    static CACHE: SocksCache = OnceLock::new();
    {
        let cache = CACHE
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some((fetched_at, list)) = cache.get(url)
            && fetched_at.elapsed() < SOCKS_FALLBACK_TTL
            && !list.is_empty()
        {
            return Some(list.clone());
        }
    }
    let fresh = fetch_socks_list(url, deadline)?;
    if let Ok(mut cache) = CACHE.get_or_init(|| Mutex::new(HashMap::new())).lock() {
        cache.insert(url.to_owned(), (Instant::now(), fresh.clone()));
    }
    Some(fresh)
}

/// Pulls a SOCKS proxy list and keeps only usable-looking entries. Any fetch,
/// parse, or shape error returns `None` so the caller can treat the fallback
/// as absent rather than failed.
fn fetch_socks_list(url: &str, deadline: Option<Instant>) -> Option<Vec<String>> {
    let timeout = remaining(deadline).ok()?.min(Duration::from_secs(15));
    let agent = ureq::Agent::new_with_config(
        ureq::config::Config::builder()
            .timeout_connect(Some(Duration::from_secs(5)))
            .timeout_global(Some(timeout))
            .build(),
    );
    let body = agent.get(url).call().ok()?.into_body().read_to_vec().ok()?;
    let entries: Vec<serde_json::Value> = serde_json::from_slice(&body).ok()?;
    let proxies = entries
        .into_iter()
        .filter_map(|entry| entry.get("proxy")?.as_str().map(str::to_owned))
        .filter(|proxy| proxy.starts_with("socks5://") || proxy.starts_with("socks4://"))
        .take(MAX_SOCKS_FALLBACK_CANDIDATES)
        .collect::<Vec<_>>();
    (!proxies.is_empty()).then_some(proxies)
}

fn route_fingerprint(endpoint: &str) -> String {
    let hash = endpoint
        .as_bytes()
        .iter()
        .fold(0xcbf29ce484222325_u64, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
        });
    format!("v1-{hash:016x}-{}", endpoint.len())
}

fn remove_if_exists(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[cfg(test)]
fn test_directory(name: &str) -> PathBuf {
    let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "portkit-github-test-{}-{sequence}-{name}",
        std::process::id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn source_capabilities_do_not_cross_match() {
        let sources = [
            (
                Capability::Release,
                "https://github.com/owner/repo/releases/download/v1/file.zip",
            ),
            (
                Capability::Raw,
                "https://raw.githubusercontent.com/owner/repo/main/file",
            ),
            (
                Capability::Archive,
                "https://github.com/owner/repo/archive/refs/heads/main.zip",
            ),
            (Capability::Api, "https://api.github.com/repos/owner/repo"),
            (
                Capability::Gist,
                "https://gist.githubusercontent.com/owner/id/raw/file",
            ),
            (Capability::Clone, "https://github.com/owner/repo.git"),
        ];
        for (expected, source) in sources {
            for capability in Capability::ALL {
                assert_eq!(
                    validate_source(capability, source).is_ok(),
                    capability == expected,
                    "{source} unexpectedly matched {capability}"
                );
            }
        }
    }

    #[test]
    fn formatters_transform_raw_sources_per_route() {
        let source = "https://raw.githubusercontent.com/owner/repo/main/path/file";
        let mirror = Route::new(
            "mirror",
            RouteFormatter::Mirror,
            [Capability::Raw],
            "https://mirror.invalid/gh",
        )
        .unwrap();
        let jsdelivr = Route::new(
            "cdn",
            RouteFormatter::Jsdelivr,
            [Capability::Raw],
            "https://cdn.invalid/gh",
        )
        .unwrap();
        assert_eq!(
            format_endpoint(&mirror, Capability::Raw, source).unwrap(),
            "https://mirror.invalid/gh/owner/repo/raw/main/path/file"
        );
        assert_eq!(
            format_endpoint(&jsdelivr, Capability::Raw, source).unwrap(),
            "https://cdn.invalid/gh/owner/repo@main/path/file"
        );
    }

    #[test]
    fn bundled_registry_limits_api_to_origin() {
        let registry = GitHubRegistry::bundled();
        let routes = registry
            .candidate_route_ids(Capability::Api, "https://api.github.com/repos/o/r")
            .unwrap();
        assert_eq!(routes, ["origin"]);
        assert!(
            registry
                .candidate_route_ids(
                    Capability::Release,
                    "https://github.com/o/r/releases/download/v/f"
                )
                .unwrap()
                .len()
                > 1
        );
    }

    #[test]
    fn changed_endpoint_discards_partial_bytes() {
        let root = test_directory("resume");
        let output = root.join("artifact");
        let part = suffixed_path(&output, ".part");
        let sidecar = suffixed_path(&output, ".part.route");
        prepare_partial(&part, &sidecar, "https://first.invalid/value").unwrap();
        fs::write(&part, b"partial").unwrap();
        prepare_partial(&part, &sidecar, "https://second.invalid/value").unwrap();
        assert!(!part.exists());
        assert_eq!(
            fs::read_to_string(sidecar).unwrap().trim(),
            route_fingerprint("https://second.invalid/value")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn batch_size_is_bounded() {
        let mut transport = GitHubTransport::new();
        assert_eq!(transport.batch_size, 5);
        assert!(transport.set_batch_size(0).is_err());
        assert!(transport.set_batch_size(10).is_ok());
        assert!(transport.set_batch_size(11).is_err());
    }

    #[test]
    fn file_fetch_rejects_clone_before_any_transfer() {
        let root = test_directory("clone-fetch");
        let output = root.join("must-not-exist");
        let transport = GitHubTransport::new();
        let error = transport
            .fetch(
                Capability::Clone,
                "https://github.com/owner/repo.git",
                &output,
                |_| true,
                None,
                None,
            )
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            "the clone capability cannot be fetched as a file"
        );
        assert!(!output.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn validation_failure_continues_to_the_next_route() {
        let root = test_directory("fallback");
        let bad_port = local_server(b"bad");
        let good_port = local_server(b"good");

        let registry = GitHubRegistry::new(vec![
            Route::new(
                "first",
                RouteFormatter::Full,
                [Capability::Release],
                format!("http://127.0.0.1:{}", bad_port),
            )
            .unwrap(),
            Route::new(
                "second",
                RouteFormatter::Full,
                [Capability::Release],
                format!("http://127.0.0.1:{}", good_port),
            )
            .unwrap(),
        ])
        .unwrap();
        let mut transport = GitHubTransport::with_registry(registry);
        transport.set_batch_size(1).unwrap();
        let output = root.join("artifact");
        let result = transport
            .fetch(
                Capability::Release,
                "https://github.com/o/r/releases/download/v/f",
                &output,
                |path| fs::read(path).is_ok_and(|bytes| bytes == b"good"),
                None,
                None,
            )
            .unwrap();
        assert_eq!(result.route_id(), "second");
        assert_eq!(fs::read(output).unwrap(), b"good");
        assert_eq!(
            transport.preferred_route(Capability::Release).as_deref(),
            Some("second")
        );
        assert_eq!(transport.preferred_route(Capability::Raw), None);
        let next_transport = GitHubTransport::new();
        assert_eq!(
            next_transport
                .preferred_route(Capability::Release)
                .as_deref(),
            Some("second")
        );
        transport.clear_preferred(Capability::Release);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn transfer_limit_rejects_an_oversized_response_and_partial_file() {
        let root = test_directory("transfer-limit");
        let port = local_server(b"too-large");
        let registry = GitHubRegistry::new(vec![
            Route::new(
                "local",
                RouteFormatter::Full,
                [Capability::Release],
                format!("http://127.0.0.1:{port}"),
            )
            .unwrap(),
        ])
        .unwrap();
        let output = root.join("artifact");
        let mut transport = GitHubTransport::with_registry(registry);
        // Do not hit the network for the dynamic SOCKS pool in unit tests.
        transport.socks_fallback_urls = Vec::new();
        let error = transport
            .fetch(
                Capability::Release,
                "https://github.com/o/r/releases/download/v/f",
                &output,
                |_| true,
                None,
                Some(4),
            )
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("all GitHub transport routes failed"),
            "unexpected error: {error}"
        );
        assert!(!output.exists());
        assert!(!suffixed_path(&output, ".part").exists());
        fs::remove_dir_all(root).unwrap();
    }

    // Minimal local HTTP/1.0 server returning a fixed body for any request,
    // used to exercise the real (native) transport in tests.
    fn local_server(body: &'static [u8]) -> u16 {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let header = format!("HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
                let _ = stream.write_all(header.as_bytes());
                let _ = stream.write_all(body);
            }
        });
        port
    }

    // Minimal SOCKS5 forward proxy: answers the greeting and CONNECT handshake,
    // then serves the tunneled request from the proxy socket itself. Used to
    // prove that Forward routes send traffic through the configured SOCKS
    // address.
    fn local_socks5_proxy(body: &'static [u8]) -> u16 {
        use std::io::{Read, Write};
        use std::net::{TcpListener, TcpStream};
        fn read_exact(stream: &mut TcpStream, n: usize) -> Vec<u8> {
            let mut out = Vec::with_capacity(n);
            while out.len() < n {
                let mut chunk = [0_u8; 64];
                let count = stream.read(&mut chunk).unwrap_or(0);
                if count == 0 {
                    break;
                }
                out.extend_from_slice(&chunk[..count]);
            }
            out
        }
        fn read_headers(stream: &mut TcpStream) {
            let mut chunk = [0_u8; 1024];
            let mut buffered = Vec::with_capacity(1024);
            while !buffered.windows(4).any(|window| window == b"\r\n\r\n") {
                let count = stream.read(&mut chunk).unwrap_or(0);
                if count == 0 {
                    return;
                }
                buffered.extend_from_slice(&chunk[..count]);
                if buffered.len() > 8192 {
                    return;
                }
            }
        }
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                // greeting: version 5, one auth method, no-auth
                let _ = read_exact(&mut stream, 3);
                let _ = stream.write_all(b"\x05\x00");
                // connect request: ver/cmd/rsv/atyp + ipv4 + port
                let _ = read_exact(&mut stream, 10);
                let _ = stream.write_all(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00");
                // tunneled request served by this socket as the origin
                read_headers(&mut stream);
                let header = format!("HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
                let _ = stream.write_all(header.as_bytes());
                let _ = stream.write_all(body);
            }
        });
        port
    }

    #[test]
    fn forward_route_validation_accepts_only_socks_proxy_addresses() {
        for ok in [
            "socks5://1.2.3.4:1080",
            "socks5h://proxy.example.com:1080",
            "socks4://1.2.3.4:1080",
            "socks5://127.0.0.1:8080",
        ] {
            assert!(valid_forward_base(ok), "{ok} should be valid");
            assert!(
                Route::new("f", RouteFormatter::Forward, [Capability::Release], ok).is_ok(),
                "{ok} should construct"
            );
        }
        for bad in [
            "socks5://1.2.3.4",
            "http://8.8.8.8:3128",
            "https://proxy.example.com:443",
            "http://127.0.0.1:8080",
            "socks5://a b:1080",
            "ftp://1.2.3.4:21",
            "socks5://user:pass@1.2.3.4:1080",
            "",
        ] {
            assert!(!valid_forward_base(bad), "{bad} should be invalid");
            assert!(
                Route::new("f", RouteFormatter::Forward, [Capability::Release], bad).is_err(),
                "{bad} should be rejected"
            );
        }
    }

    #[test]
    fn forward_routes_keep_the_source_url_and_carry_the_proxy_address() {
        let route = Route::new(
            "proxy1",
            RouteFormatter::Forward,
            [Capability::Release, Capability::Raw],
            "socks5://1.2.3.4:1080",
        )
        .unwrap();
        let source = "https://github.com/o/r/releases/download/v/f";
        assert_eq!(
            format_endpoint(&route, Capability::Release, source).unwrap(),
            source
        );
        assert_eq!(
            route.forward_proxy().as_deref(),
            Some("socks5://1.2.3.4:1080")
        );
        let mirror = Route::new(
            "m",
            RouteFormatter::Full,
            [Capability::Release],
            "https://mirror.example",
        )
        .unwrap();
        assert_eq!(mirror.forward_proxy(), None);
    }

    #[test]
    fn candidates_expose_forward_proxies_without_rewriting_the_source() {
        let registry = GitHubRegistry::new(vec![
            Route::new(
                "fwd",
                RouteFormatter::Forward,
                [Capability::Release],
                "socks5://1.2.3.4:1080",
            )
            .unwrap(),
        ])
        .unwrap();
        let candidates = registry
            .candidates(
                Capability::Release,
                "https://github.com/o/r/releases/download/v/f",
            )
            .unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].route_id(), "fwd");
        assert_eq!(
            candidates[0].endpoint(),
            "https://github.com/o/r/releases/download/v/f"
        );
        assert_eq!(
            candidates[0].proxy.as_deref(),
            Some("socks5://1.2.3.4:1080")
        );
    }

    #[test]
    fn probe_reaches_unreachable_origins_through_the_forward_proxy() {
        let port = local_socks5_proxy(b"x");
        let transport = GitHubTransport::new();
        let candidate = GitHubCandidate {
            route_id: "f".to_owned(),
            endpoint: "http://127.0.0.1:9/artifact".to_owned(),
            proxy: Some(format!("socks5://127.0.0.1:{port}")),
        };
        assert!(transport.probe(&candidate, None));
    }

    #[test]
    fn single_transfer_fetches_through_the_configured_forward_proxy() {
        let root = test_directory("forward-transfer");
        let port = local_socks5_proxy(b"via-proxy");
        let part = root.join("artifact.part");
        let sidecar = root.join("artifact.part.route");
        GitHubTransport::new()
            .single_transfer(
                "http://127.0.0.1:9/artifact",
                Some(&format!("socks5://127.0.0.1:{port}")),
                &part,
                &sidecar,
                None,
                Some(64),
                None,
            )
            .unwrap();
        assert_eq!(fs::read(&part).unwrap(), b"via-proxy");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn content_range_must_bind_the_exact_partial_and_total() {
        assert_eq!(
            parse_content_range(Some("bytes 4-7/8"), 4, Some(8)),
            Some(8)
        );
        assert_eq!(parse_content_range(Some("bytes 0-3/8"), 4, Some(8)), None);
        assert_eq!(parse_content_range(Some("bytes 4-7/9"), 4, Some(9)), None);
        assert_eq!(parse_content_range(Some("bytes 4-8/8"), 4, None), None);
        assert_eq!(parse_content_range(Some("garbage"), 4, None), None);
    }

    #[test]
    fn cleartext_registry_and_spoofed_loopback_hosts_are_rejected() {
        assert!(!CUSTOM_ROUTES.contains("jsdelivr"));
        assert!(!FULL_ROUTES.contains("gh-proxy"));
        assert!(
            Route::new(
                "local",
                RouteFormatter::Full,
                [Capability::Release],
                "http://localhost:1234"
            )
            .is_ok()
        );
        assert!(
            Route::new(
                "spoof",
                RouteFormatter::Full,
                [Capability::Release],
                "http://localhost.evil:1234"
            )
            .is_err()
        );
        assert!(
            Route::new(
                "spoof",
                RouteFormatter::Full,
                [Capability::Release],
                "http://[::1].evil:1234"
            )
            .is_err()
        );
        assert!(
            Route::new(
                "spoof",
                RouteFormatter::Full,
                [Capability::Release],
                "http://127.0.0.1.evil:1234"
            )
            .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn partial_symlinks_and_concurrent_writers_are_rejected() {
        use std::os::unix::fs::symlink;

        let root = test_directory("temp-safety");
        let output = root.join("artifact");
        let part = suffixed_path(&output, ".part");
        let victim = root.join("victim");
        fs::write(&victim, b"keep").unwrap();
        symlink(&victim, &part).unwrap();
        assert!(
            prepare_partial(
                &part,
                &suffixed_path(&output, ".part.route"),
                "https://example.invalid/value"
            )
            .is_err()
        );
        assert_eq!(fs::read(&victim).unwrap(), b"keep");

        fs::remove_file(part).unwrap();
        let first = TransferLock::acquire(&output).unwrap();
        assert_eq!(
            TransferLock::acquire(&output).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        drop(first);
        drop(TransferLock::acquire(&output).unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_resume_range_is_restarted_without_appending() {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            for request_index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 2048];
                let count = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..count]).to_ascii_lowercase();
                if request_index == 0 {
                    assert!(request.contains("range: bytes=3-"));
                    assert!(request.contains("if-range: \"entity-1\""));
                    stream
                        .write_all(
                            b"HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 0-3/4\r\nETag: \"entity-1\"\r\nConnection: close\r\n\r\ngood",
                        )
                        .unwrap();
                } else {
                    assert!(!request.contains("range:"));
                    stream
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nETag: \"entity-2\"\r\nConnection: close\r\n\r\ngood",
                        )
                        .unwrap();
                }
            }
        });
        let root = test_directory("range-restart");
        let endpoint = format!("http://127.0.0.1:{port}/artifact");
        let part = root.join("artifact.part");
        let sidecar = root.join("artifact.part.route");
        fs::write(&part, b"bad").unwrap();
        write_partial_state(&sidecar, &endpoint, Some("\"entity-1\"")).unwrap();
        GitHubTransport::new()
            .single_transfer(&endpoint, None, &part, &sidecar, None, Some(4), None)
            .unwrap();
        server.join().unwrap();
        assert_eq!(fs::read(&part).unwrap(), b"good");
        assert_eq!(
            partial_validator(&sidecar).unwrap().as_deref(),
            Some("\"entity-2\"")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn strong_validator_preserves_same_route_resume() {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 2048];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]).to_ascii_lowercase();
            assert!(request.contains("range: bytes=3-"));
            assert!(request.contains("if-range: \"entity-1\""));
            stream
                .write_all(
                    b"HTTP/1.1 206 Partial Content\r\nContent-Length: 1\r\nContent-Range: bytes 3-3/4\r\nETag: \"entity-1\"\r\nConnection: close\r\n\r\nd",
                )
                .unwrap();
        });
        let root = test_directory("range-resume");
        let endpoint = format!("http://127.0.0.1:{port}/artifact");
        let part = root.join("artifact.part");
        let sidecar = root.join("artifact.part.route");
        fs::write(&part, b"goo").unwrap();
        write_partial_state(&sidecar, &endpoint, Some("\"entity-1\"")).unwrap();
        GitHubTransport::new()
            .single_transfer(&endpoint, None, &part, &sidecar, None, Some(4), None)
            .unwrap();
        server.join().unwrap();
        assert_eq!(fs::read(&part).unwrap(), b"good");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn fetch_socks_list_filters_and_limits_entries() {
        // 60 socks5 entries (over the 50 cap) plus one http and one socks4.
        let mut body = String::from("[");
        for index in 0..60 {
            body.push_str(&format!(r#"{{"proxy":"socks5://10.0.0.{index}:1080"}},"#));
        }
        body.push_str(r#"{"proxy":"http://8.8.8.8:80"},"#);
        body.push_str(r#"{"proxy":"socks4://9.9.9.9:1080"}]"#);
        let list = Box::leak(body.into_boxed_str());
        let port = local_server(list.as_bytes());
        let url = format!("http://127.0.0.1:{port}/list.json");
        let proxies = fetch_socks_list(&url, None).unwrap();
        assert_eq!(proxies.len(), MAX_SOCKS_FALLBACK_CANDIDATES);
        assert!(proxies.iter().all(|p| p.starts_with("socks5://10.0.0.")));
        assert_eq!(proxies[0], "socks5://10.0.0.0:1080");
        assert_eq!(proxies[49], "socks5://10.0.0.49:1080");
    }

    #[test]
    fn socks_fallback_tries_sources_in_order_until_one_responds() {
        let socks_port = local_socks5_proxy(b"probe-ok");
        let list_body = format!(r#"[{{"proxy":"socks5://127.0.0.1:{socks_port}"}}]"#);
        let list_url = Box::leak(list_body.into_boxed_str());
        let list_port = local_server(list_url.as_bytes());
        let mut transport = GitHubTransport::new();
        // First source refuses to connect; the second must be used.
        transport.socks_fallback_urls = vec![
            "http://127.0.0.1:1/list.json".to_owned(),
            format!("http://127.0.0.1:{list_port}/list.json"),
        ];
        let candidates = transport
            .socks_fallback_candidates(Capability::Raw, "https://github.com/o/r/raw/main/f", None)
            .unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].route_id(), "socks1");
        assert!(
            candidates[0]
                .proxy
                .as_deref()
                .unwrap()
                .starts_with("socks5://")
        );
    }

    #[test]
    fn socks_fallback_builds_candidates_from_the_remote_list() {
        let socks_port = local_socks5_proxy(b"probe-ok");
        let list_body = format!(
            r#"[{{"proxy":"socks5://127.0.0.1:{socks_port}"}},{{"proxy":"socks5://10.9.9.9:1080"}}]"#
        );
        let list_url = Box::leak(list_body.into_boxed_str());
        let list_port = local_server(list_url.as_bytes());
        let mut transport = GitHubTransport::new();
        transport.socks_fallback_urls = vec![format!("http://127.0.0.1:{list_port}/list.json")];
        let candidates = transport
            .socks_fallback_candidates(Capability::Raw, "https://github.com/o/r/raw/main/f", None)
            .unwrap();
        assert_eq!(candidates.len(), 2);
        assert_eq!(candidates[0].route_id(), "socks1");
        assert_eq!(
            candidates[0].endpoint(),
            "https://github.com/o/r/raw/main/f"
        );
        assert!(
            candidates[0]
                .proxy
                .as_deref()
                .unwrap()
                .starts_with("socks5://")
        );
        // The live local proxy answers a probe through the SOCKS tunnel; the
        // unreachable origin host proves the request went through the proxy.
        let probed = GitHubCandidate {
            route_id: "p".to_owned(),
            endpoint: "http://127.0.0.1:9/artifact".to_owned(),
            proxy: candidates[0].proxy.clone(),
        };
        assert!(transport.probe(&probed, None));
    }

    #[test]
    fn socks_fallback_stays_silent_when_the_list_cannot_be_fetched() {
        let registry = GitHubRegistry::new(vec![
            Route::new(
                "dead",
                RouteFormatter::Mirror,
                [Capability::Release],
                "http://127.0.0.1:1",
            )
            .unwrap(),
        ])
        .unwrap();
        let mut transport = GitHubTransport::with_registry(registry);
        transport.socks_fallback_urls = vec!["http://127.0.0.1:1/list.json".to_owned()];
        let root = test_directory("socks-fallback-silent");
        let error = transport
            .fetch(
                Capability::Release,
                "https://github.com/o/r/releases/download/v/f",
                &root.join("artifact"),
                |_| true,
                None,
                Some(64),
            )
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("all GitHub transport routes failed"),
            "unexpected error: {error}"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
