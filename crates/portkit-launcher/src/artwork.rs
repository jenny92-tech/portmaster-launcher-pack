//! Frontend-owned Port artwork placement for tested handheld layouts.
//!
//! The device-layout knowledge used to live in `_kit/launcher_artwork.sh`;
//! keeping it here makes it unit-testable and stops the shell copy drifting
//! from the platform configs. Only verified MiniLoong and TrimUI layouts are
//! resolved; unknown devices are deliberately left untouched until tested.

use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

/// Filesystem markers that identify a device family. Overridable so tests can
/// stage fake devices; the environment names match the historical shell ones.
pub struct ProbeMarkers {
    pub loong_version_file: PathBuf,
    pub trimui_marker_dir: PathBuf,
}

impl Default for ProbeMarkers {
    fn default() -> Self {
        let env_path = |name: &str, fallback: &str| {
            std::env::var_os(name)
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(fallback))
        };
        Self {
            loong_version_file: env_path("PORTMASTER_LOONG_VERSION_FILE", "/loong/loong_version"),
            trimui_marker_dir: env_path("PORTMASTER_TRIMUI_MARKER_DIR", "/usr/trimui"),
        }
    }
}

/// Resolves the frontend-owned image directory for the launcher's script
/// directory, or `None` when the device layout is not recognised.
pub fn probe_image_dir(script_dir: &Path, markers: &ProbeMarkers) -> Option<PathBuf> {
    if markers.loong_version_file.is_file() {
        return Some(script_dir.join("images"));
    }
    let case_is = |component: Option<Component>, want: &str| {
        component
            .and_then(|value| value.as_os_str().to_str())
            .is_some_and(|value| value.eq_ignore_ascii_case(want))
    };
    let mut components = script_dir.components().rev();
    if case_is(components.next(), "ports") && case_is(components.next(), "roms") {
        let card_root = script_dir.parent()?.parent()?;
        if markers.trimui_marker_dir.is_dir() || card_root.join("Emus/PORTS/config.json").is_file()
        {
            return Some(card_root.join("Imgs/PORTS"));
        }
    }
    None
}

#[derive(Debug, PartialEq, Eq)]
pub enum SyncOutcome {
    /// Nothing to do; the reason names the first guard that declined.
    Skipped(&'static str),
    /// Frontend artwork already present; never overwritten.
    Existing(PathBuf),
    Copied(PathBuf),
}

const IMAGE_EXTENSIONS: [&str; 8] = ["png", "PNG", "jpg", "JPG", "jpeg", "JPEG", "webp", "WEBP"];

/// Copies the package image whose stem exactly matches the launcher's stem
/// into the frontend image directory. No fuzzy fallback, so one package can
/// never publish another launcher's artwork; existing artwork is kept.
pub fn sync_launcher_artwork(
    script_dir: &Path,
    launcher: &Path,
    source_dir: &Path,
    markers: &ProbeMarkers,
) -> io::Result<SyncOutcome> {
    let stem = launcher
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_suffix(".sh"))
        .unwrap_or("");
    if stem.is_empty() || stem == ".port" {
        return Ok(SyncOutcome::Skipped("launcher-stem"));
    }
    let source = IMAGE_EXTENSIONS.iter().find_map(|extension| {
        let candidate = source_dir.join(format!("{stem}.{extension}"));
        (candidate.is_file() && !candidate.is_symlink()).then_some((candidate, *extension))
    });
    let Some((source, extension)) = source else {
        return Ok(SyncOutcome::Skipped("no-package-image"));
    };
    let Some(image_dir) = probe_image_dir(script_dir, markers) else {
        return Ok(SyncOutcome::Skipped("unknown-layout"));
    };
    if image_dir.is_symlink() {
        return Ok(SyncOutcome::Skipped("image-dir-symlink"));
    }
    if !image_dir.is_dir() {
        fs::create_dir_all(&image_dir)?;
    }
    let target = image_dir.join(format!("{stem}.{extension}"));
    if target.exists() || target.is_symlink() {
        return Ok(SyncOutcome::Existing(target));
    }
    fs::copy(&source, &target)?;
    Ok(SyncOutcome::Copied(target))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn markers(temp: &Path) -> ProbeMarkers {
        ProbeMarkers {
            loong_version_file: temp.join("absent-loong-version"),
            trimui_marker_dir: temp.join("absent-trimui-marker"),
        }
    }

    #[test]
    fn loong_marker_resolves_script_local_images() {
        let temp = tempfile::tempdir().unwrap();
        let mut markers = markers(temp.path());
        fs::write(temp.path().join("loong_version"), b"1").unwrap();
        markers.loong_version_file = temp.path().join("loong_version");
        let scripts = temp.path().join("ports");
        assert_eq!(
            probe_image_dir(&scripts, &markers),
            Some(scripts.join("images"))
        );
    }

    #[test]
    fn trimui_layout_resolves_card_image_dir_case_insensitively() {
        let temp = tempfile::tempdir().unwrap();
        let markers = markers(temp.path());
        for variant in ["Roms/PORTS", "roms/ports", "ROMS/Ports"] {
            let card = temp.path().join(variant.replace('/', "_"));
            let scripts = card.join(variant);
            fs::create_dir_all(card.join("Emus/PORTS")).unwrap();
            fs::write(card.join("Emus/PORTS/config.json"), b"{}").unwrap();
            fs::create_dir_all(&scripts).unwrap();
            assert_eq!(
                probe_image_dir(&scripts, &markers),
                Some(card.join("Imgs/PORTS")),
                "variant {variant}"
            );
        }
    }

    #[test]
    fn unknown_layout_is_left_untouched() {
        let temp = tempfile::tempdir().unwrap();
        let markers = markers(temp.path());
        let scripts = temp.path().join("somewhere/else");
        fs::create_dir_all(&scripts).unwrap();
        assert_eq!(probe_image_dir(&scripts, &markers), None);
        let outcome = sync_launcher_artwork(
            &scripts,
            &scripts.join("Game.sh"),
            &scripts,
            &markers,
        )
        .unwrap();
        assert_eq!(outcome, SyncOutcome::Skipped("no-package-image"));
    }

    #[test]
    fn syncs_exact_stem_once_and_never_overwrites() {
        let temp = tempfile::tempdir().unwrap();
        let markers = markers(temp.path());
        let card = temp.path().join("card");
        let scripts = card.join("Roms/PORTS");
        let game = card.join("Data/ports/game");
        fs::create_dir_all(card.join("Emus/PORTS")).unwrap();
        fs::write(card.join("Emus/PORTS/config.json"), b"{}").unwrap();
        fs::create_dir_all(&scripts).unwrap();
        fs::create_dir_all(&game).unwrap();
        fs::write(game.join("Game.png"), b"art").unwrap();
        fs::write(game.join("Other.png"), b"other").unwrap();

        let launcher = scripts.join("Game.sh");
        let copied = sync_launcher_artwork(&scripts, &launcher, &game, &markers).unwrap();
        let target = card.join("Imgs/PORTS/Game.png");
        assert_eq!(copied, SyncOutcome::Copied(target.clone()));
        assert_eq!(fs::read(&target).unwrap(), b"art");

        fs::write(&target, b"frontend-owned").unwrap();
        let kept = sync_launcher_artwork(&scripts, &launcher, &game, &markers).unwrap();
        assert_eq!(kept, SyncOutcome::Existing(target.clone()));
        assert_eq!(fs::read(&target).unwrap(), b"frontend-owned");

        // A renamed launcher has no exactly-matching stem: nothing is copied.
        let renamed = sync_launcher_artwork(&scripts, &scripts.join("Renamed.sh"), &game, &markers)
            .unwrap();
        assert_eq!(renamed, SyncOutcome::Skipped("no-package-image"));
    }
}
