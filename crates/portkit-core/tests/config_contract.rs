use portkit_core::{
    CandidateSelector, ConfigCandidate, ConfigLoader, ConfigOrigin, DetectionContext,
    FragmentSource, HealthStatus, LocalFragmentSource, evaluate_health,
};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

fn config_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config")
}

fn platform_config(platform_id: &str) -> portkit_core::Config {
    let loader = ConfigLoader::default();
    let root = loader
        .parse_root(&std::fs::read(config_dir().join("config.json")).unwrap())
        .unwrap();
    loader
        .load_platform(root, platform_id, &LocalFragmentSource::new(config_dir()))
        .unwrap()
}

#[test]
fn two_tier_load_reads_only_the_detected_platform() {
    let loader = ConfigLoader::default();
    let root_bytes = std::fs::read(config_dir().join("config.json")).unwrap();
    let details = RecordingSource::new(LocalFragmentSource::new(config_dir()));
    let context = DetectionContext {
        root: Some(std::env::temp_dir().join(format!("portkit-equiv-{}", std::process::id()))),
        launcher_path: "/mnt/SDCARD/Roms/PORTS/Test.sh".into(),
        environment: [("CFW_NAME".to_string(), "TrimUI".to_string())]
            .into_iter()
            .collect(),
        os_release: BTreeMap::new(),
        target_override: None,
    };
    let config = loader
        .load_for_context(&root_bytes, &details, &context)
        .unwrap();
    assert_eq!(config.platforms.keys().collect::<Vec<_>>(), vec!["trimui"]);
    assert_eq!(details.reads(), vec!["./platforms/trimui.json"]);
}

struct RecordingSource<S> {
    inner: S,
    reads: RefCell<Vec<String>>,
}

impl<S> RecordingSource<S> {
    fn new(inner: S) -> Self {
        Self {
            inner,
            reads: RefCell::new(Vec::new()),
        }
    }

    fn reads(&self) -> Vec<String> {
        self.reads.borrow().clone()
    }
}

impl<S: FragmentSource> FragmentSource for RecordingSource<S> {
    fn read(&self, ref_path: &str) -> portkit_core::Result<Vec<u8>> {
        self.reads.borrow_mut().push(ref_path.to_owned());
        self.inner.read(ref_path)
    }
}

struct MemorySource(BTreeMap<String, Vec<u8>>);

impl FragmentSource for MemorySource {
    fn read(&self, ref_path: &str) -> portkit_core::Result<Vec<u8>> {
        self.0.get(ref_path).cloned().ok_or_else(|| {
            portkit_core::Error::InvalidConfig(format!("missing test fragment {ref_path}"))
        })
    }
}

fn trimui_context() -> DetectionContext {
    DetectionContext {
        root: Some(PathBuf::from("/definitely-not-a-device")),
        launcher_path: "/mnt/SDCARD/Roms/PORTS/Test.sh".into(),
        environment: [("CFW_NAME".into(), "TrimUI".into())].into_iter().collect(),
        os_release: BTreeMap::new(),
        target_override: None,
    }
}

#[test]
fn detail_identity_and_parser_limits_are_enforced() {
    let loader = ConfigLoader::default();
    let mut root: serde_json::Value =
        serde_json::from_slice(&std::fs::read(config_dir().join("config.json")).unwrap()).unwrap();
    let mut detail: serde_json::Value =
        serde_json::from_slice(&std::fs::read(config_dir().join("platforms/trimui.json")).unwrap())
            .unwrap();
    detail["config_version"] = "0.0.1".into();
    let detail_bytes = serde_json::to_vec(&detail).unwrap();
    let source = MemorySource(BTreeMap::from([(
        "./platforms/trimui.json".into(),
        detail_bytes,
    )]));
    assert!(
        loader
            .load_for_context(
                &serde_json::to_vec(&root).unwrap(),
                &source,
                &trimui_context()
            )
            .unwrap_err()
            .to_string()
            .contains("config_version")
    );

    detail["config_version"] = root["config_version"].clone();
    detail["future"] = "x".repeat(101).into();
    root["parser_limits"]["max_string_bytes"] = 100.into();
    let detail_bytes = serde_json::to_vec(&detail).unwrap();
    let source = MemorySource(BTreeMap::from([(
        "./platforms/trimui.json".into(),
        detail_bytes,
    )]));
    assert!(
        loader
            .load_for_context(
                &serde_json::to_vec(&root).unwrap(),
                &source,
                &trimui_context()
            )
            .unwrap_err()
            .to_string()
            .contains("max_string_bytes")
    );
}

#[test]
fn generated_details_keep_detection_in_root_and_parentage_in_containment() {
    let detail: serde_json::Value =
        serde_json::from_slice(&std::fs::read(config_dir().join("platforms/trimui.json")).unwrap())
            .unwrap();
    assert!(detail.get("priority").is_none());
    assert!(detail.get("recognition").is_none());
    for model in detail["models"].as_object().unwrap().values() {
        assert!(model.get("inherits").is_none());
    }
}

#[test]
fn model_recognition_predicates_are_strictly_validated() {
    let loader = ConfigLoader::default();
    let root: serde_json::Value =
        serde_json::from_slice(&std::fs::read(config_dir().join("config.json")).unwrap()).unwrap();
    let mut detail: serde_json::Value =
        serde_json::from_slice(&std::fs::read(config_dir().join("platforms/trimui.json")).unwrap())
            .unwrap();
    detail["models"]["smart_pro"]["recognition"] = serde_json::json!({"kind": "run_shell"});
    let detail_bytes = serde_json::to_vec(&detail).unwrap();
    let source = MemorySource(BTreeMap::from([(
        "./platforms/trimui.json".into(),
        detail_bytes,
    )]));
    let config = loader
        .load_for_context(
            &serde_json::to_vec(&root).unwrap(),
            &source,
            &trimui_context(),
        )
        .unwrap();
    let error = loader
        .validate_resolved_closure(&config, "trimui")
        .unwrap_err();
    assert!(
        matches!(error, portkit_core::Error::InvalidConfig(_)),
        "{error}"
    );
    assert!(error.to_string().contains("smart_pro"), "{error}");
}

#[test]
fn health_rule_kinds_match_the_schema_enum() {
    let schema: serde_json::Value = serde_json::from_slice(
        &std::fs::read(config_dir().join("appmanager-config.schema.json")).unwrap(),
    )
    .unwrap();
    let schema_kinds: std::collections::BTreeSet<&str> =
        schema["$defs"]["healthRule"]["properties"]["kind"]["enum"]
            .as_array()
            .unwrap()
            .iter()
            .map(|kind| kind.as_str().unwrap())
            .collect();
    // Rust implements the required file-based kinds (HEALTH_REQUIRED_KINDS)
    // plus the deliberate python_imports_or_runtime special path.
    let rust_kinds: std::collections::BTreeSet<&str> = portkit_core::health::HEALTH_REQUIRED_KINDS
        .split(',')
        .chain(["python_imports_or_runtime"])
        .collect();
    assert_eq!(schema_kinds, rust_kinds);
}

fn schema_enum(path: &[&str]) -> std::collections::BTreeSet<String> {
    let schema: serde_json::Value = serde_json::from_slice(
        &std::fs::read(config_dir().join("appmanager-config.schema.json")).unwrap(),
    )
    .unwrap();
    let mut node = &schema;
    for segment in path {
        node = &node[*segment];
    }
    node.as_array()
        .unwrap_or_else(|| panic!("schema has no enum at {path:?}"))
        .iter()
        .map(|kind| kind.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn predicate_kinds_match_the_schema_enum() {
    // Keep in sync with the match arms in `Predicate::validate`
    // (crates/portkit-core/src/predicate.rs).
    let rust_kinds: std::collections::BTreeSet<String> = [
        "always",
        "all",
        "any",
        "directory_exists",
        "file_exists",
        "launcher_path_prefix",
        "env_equals",
        "os_release_equals",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    let schema_kinds = schema_enum(&["$defs", "predicate", "properties", "kind", "enum"]);
    assert_eq!(schema_kinds, rust_kinds);
}

#[test]
fn path_strategy_kinds_match_the_schema_enum() {
    // Keep in sync with the match arms in `PathStrategy::validate`
    // (crates/portkit-core/src/platform.rs).
    let rust_kinds: std::collections::BTreeSet<String> = [
        "literal",
        "first_existing",
        "launcher_dir",
        "platform_core",
        "rom_root_from_launcher",
        "xdg_data_home",
        "literal_by_launcher_prefix",
        "parent",
        "relative_to",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    let schema_kinds = schema_enum(&["$defs", "pathStrategy", "properties", "strategy", "enum"]);
    assert_eq!(schema_kinds, rust_kinds);
}

#[test]
fn environment_operation_kinds_match_the_schema_enum() {
    // Keep in sync with the `EnvironmentOperation` variants (snake_case tag)
    // in crates/portkit-core/src/environment.rs. The `prepend_path`/`append_path`
    // serde aliases are backward-compat input spellings, not vocabulary.
    let rust_kinds: std::collections::BTreeSet<String> = ["set", "prepend", "append", "unset"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    let schema_kinds = schema_enum(&[
        "$defs",
        "environmentOperation",
        "properties",
        "operation",
        "enum",
    ]);
    assert_eq!(schema_kinds, rust_kinds);
}

#[test]
fn device_classes_match_the_schema_enum() {
    // Keep in sync with the `device_class` validation in `Platform::validate`
    // (crates/portkit-core/src/platform.rs).
    let rust_kinds: std::collections::BTreeSet<String> =
        ["tested", "official-untested", "unsupported-known"]
            .into_iter()
            .map(str::to_owned)
            .collect();
    let schema_kinds = schema_enum(&["$defs", "support", "properties", "device_class", "enum"]);
    assert_eq!(schema_kinds, rust_kinds);
}

fn versioned_remote_fixture(version: &str) -> (Vec<u8>, MemorySource) {
    let mut root: serde_json::Value =
        serde_json::from_slice(&std::fs::read(config_dir().join("config.json")).unwrap()).unwrap();
    let mut detail: serde_json::Value =
        serde_json::from_slice(&std::fs::read(config_dir().join("platforms/trimui.json")).unwrap())
            .unwrap();
    root["config_version"] = version.into();
    detail["config_version"] = version.into();
    let detail_bytes = serde_json::to_vec(&detail).unwrap();
    (
        serde_json::to_vec(&root).unwrap(),
        MemorySource(BTreeMap::from([(
            "./platforms/trimui.json".into(),
            detail_bytes,
        )])),
    )
}

#[test]
fn root_selection_is_newer_only_and_remote_detail_failure_falls_back() {
    let embedded = std::fs::read(config_dir().join("config.json")).unwrap();
    let embedded_details = LocalFragmentSource::new(config_dir());
    let selector = CandidateSelector {
        loader: ConfigLoader::default(),
    };
    let (newer, newer_details) = versioned_remote_fixture("9.0.0");
    let selection = selector
        .select_root_for_context(
            ConfigCandidate::embedded(embedded.clone()),
            &embedded_details,
            Some((ConfigCandidate::remote(newer.clone()), &newer_details)),
            &trimui_context(),
        )
        .unwrap();
    assert_eq!(selection.selected.origin, ConfigOrigin::Remote);

    let missing = MemorySource(BTreeMap::new());
    let selection = selector
        .select_root_for_context(
            ConfigCandidate::embedded(embedded.clone()),
            &embedded_details,
            Some((ConfigCandidate::remote(newer), &missing)),
            &trimui_context(),
        )
        .unwrap();
    assert_eq!(selection.selected.origin, ConfigOrigin::Embedded);

    let (older, older_details) = versioned_remote_fixture("0.9.0");
    let selection = selector
        .select_root_for_context(
            ConfigCandidate::embedded(embedded),
            &embedded_details,
            Some((ConfigCandidate::remote(older), &older_details)),
            &trimui_context(),
        )
        .unwrap();
    assert_eq!(selection.selected.origin, ConfigOrigin::Embedded);
}

#[test]
fn remote_root_allows_safe_environment_and_ignores_unselected_future_data() {
    let embedded = std::fs::read(config_dir().join("config.json")).unwrap();
    let embedded_details = LocalFragmentSource::new(config_dir());
    let selector = CandidateSelector {
        loader: ConfigLoader::default(),
    };
    let (remote, details) = versioned_remote_fixture("9.0.0");
    let mut remote: serde_json::Value = serde_json::from_slice(&remote).unwrap();
    remote["environment"]["scopes"]["love_ui"]["operations"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "operation": "set", "name": "REMOTE_ALLOWED", "value": "yes"
        }));
    remote["adapters"]["future.v99"] =
        serde_json::json!({"kind":"future_kind","contract_version":99});
    remote["platforms"]["future-device"] = serde_json::json!({
        "priority": 2000,
        "recognition": {"kind":"env_equals","name":"FUTURE_DEVICE","value":"1"},
        "detail": "./platforms/future-device.json"
    });
    let selection = selector
        .select_root_for_context(
            ConfigCandidate::embedded(embedded.clone()),
            &embedded_details,
            Some((
                ConfigCandidate::remote(serde_json::to_vec(&remote).unwrap()),
                &details,
            )),
            &trimui_context(),
        )
        .unwrap();
    assert_eq!(selection.selected.origin, ConfigOrigin::Remote);
    assert!(
        selection
            .selected
            .config
            .adapters
            .contains_key("future.v99")
    );

    remote["environment"]["blocked_names"]
        .as_array_mut()
        .unwrap()
        .retain(|name| name != "LD_PRELOAD");
    let selection = selector
        .select_root_for_context(
            ConfigCandidate::embedded(embedded),
            &embedded_details,
            Some((
                ConfigCandidate::remote(serde_json::to_vec(&remote).unwrap()),
                &details,
            )),
            &trimui_context(),
        )
        .unwrap();
    assert_eq!(selection.selected.origin, ConfigOrigin::Embedded);
}

#[test]
fn local_fragments_reject_absolute_traversal_and_symlink_escape() {
    let fixture = tempfile_dir("safe-refs");
    let base = fixture.join("config");
    std::fs::create_dir_all(base.join("platforms")).unwrap();
    std::fs::write(fixture.join("outside.json"), b"{}\n").unwrap();
    let source = LocalFragmentSource::new(&base);
    assert!(source.read("../outside.json").is_err());
    assert!(
        source
            .read(fixture.join("outside.json").to_str().unwrap())
            .is_err()
    );
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&fixture, base.join("platforms/escape")).unwrap();
        assert!(source.read("./platforms/escape/outside.json").is_err());
    }
    let _ = std::fs::remove_dir_all(fixture);
}

fn tempfile_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "portkit-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

#[test]
fn generated_contract_loads_and_every_current_platform_has_a_supported_closure() {
    let loader = ConfigLoader::default();
    let root = loader
        .parse_root(&std::fs::read(config_dir().join("config.json")).unwrap())
        .unwrap();
    for platform in root.platforms.keys() {
        let config = platform_config(platform);
        let closure = loader.validate_resolved_closure(&config, platform).unwrap();
        assert!(!closure.is_empty(), "{platform} has no adapters");
    }
}

#[test]
fn model_and_platform_resolution_is_deterministic() {
    let loader = ConfigLoader::default();
    let config = platform_config("trimui");
    let context = DetectionContext {
        root: Some(PathBuf::from("/definitely-not-a-device")),
        launcher_path: "/mnt/SDCARD/Roms/PORTS/Test.sh".into(),
        environment: BTreeMap::from([
            ("CFW_NAME".into(), "TrimUI".into()),
            ("DEVICE".into(), "SMART-PRO".into()),
        ]),
        os_release: BTreeMap::new(),
        target_override: None,
    };
    let resolution = config.detect_and_resolve(&loader, &context).unwrap();
    assert_eq!(resolution.platform_id, "trimui");
    assert_eq!(resolution.device_manufacturer.as_deref(), Some("TrimUI"));
    assert_eq!(resolution.model_id.as_deref(), Some("smart_pro"));
    assert_eq!(
        resolution.paths["images"],
        PathBuf::from("/mnt/SDCARD/Imgs/PORTS")
    );
}

#[test]
fn unused_future_adapter_is_tolerated_but_rejected_in_selected_closure() {
    let loader = ConfigLoader::default();
    let mut config = platform_config("miniloong");
    config.adapters.insert(
        "future.v99".into(),
        portkit_core::config::Adapter {
            kind: "future_kind".into(),
            contract_version: 99,
            requires: vec![],
            extra: BTreeMap::new(),
        },
    );
    loader
        .validate_resolved_closure(&config, "miniloong")
        .unwrap();
    config
        .platforms
        .get_mut("miniloong")
        .unwrap()
        .required_adapters
        .push("future.v99".into());
    assert!(
        loader
            .validate_resolved_closure(&config, "miniloong")
            .is_err()
    );
}

#[test]
fn newer_remote_config_can_update_known_platform_capabilities_and_paths() {
    let loader = ConfigLoader::default();
    let embedded = std::fs::read(config_dir().join("config.json")).unwrap();
    let embedded_details = LocalFragmentSource::new(config_dir());
    let mut remote: serde_json::Value = serde_json::from_slice(&embedded).unwrap();
    let mut detail: serde_json::Value = serde_json::from_slice(
        &std::fs::read(config_dir().join("platforms/rocknix.json")).unwrap(),
    )
    .unwrap();
    remote["config_version"] = "9.0.0".into();
    detail["config_version"] = "9.0.0".into();
    detail["capabilities"]["install_portmaster"] = true.into();
    detail["frontend"]["management"] = "app".into();
    detail["paths"]["portmaster_core"] =
        serde_json::json!({"strategy":"literal","value":"/updated/PortMaster"});
    let detail_bytes = serde_json::to_vec(&detail).unwrap();
    let remote_details = MemorySource(BTreeMap::from([(
        "./platforms/rocknix.json".into(),
        detail_bytes,
    )]));
    let selector = CandidateSelector { loader };
    let context = rocknix_context();
    let selection = selector
        .select_root_for_context(
            ConfigCandidate::embedded(embedded.clone()),
            &embedded_details,
            Some((
                ConfigCandidate::remote(serde_json::to_vec(&remote).unwrap()),
                &remote_details,
            )),
            &context,
        )
        .unwrap();
    assert_eq!(selection.selected.origin, ConfigOrigin::Remote);
    assert_eq!(selection.resolution.platform_id, "rocknix");
    assert!(selection.resolution.capabilities["install_portmaster"]);
    assert!(selection.resolution.paths["portmaster_core"].ends_with("updated/PortMaster"));
}

#[test]
fn configured_json_limits_are_enforced_without_a_total_file_limit() {
    let loader = ConfigLoader::default();
    let raw = std::fs::read(config_dir().join("config.json")).unwrap();
    let mut config: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    config["parser_limits"]["max_string_bytes"] = 3.into();
    assert!(
        loader
            .parse_root(&serde_json::to_vec(&config).unwrap())
            .is_err()
    );

    let mut config: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    config["parser_limits"]["max_collection_items"] = 1.into();
    assert!(
        loader
            .parse_root(&serde_json::to_vec(&config).unwrap())
            .is_err()
    );

    let mut config: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    config["parser_limits"]["max_depth"] = 2.into();
    assert!(
        loader
            .parse_root(&serde_json::to_vec(&config).unwrap())
            .is_err()
    );
}

#[test]
fn generic_missing_target_is_unconfirmed_until_explicitly_overridden() {
    let loader = ConfigLoader::default();
    let config = platform_config("generic");
    let root = std::env::temp_dir().join(format!("portkit-generic-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let mut context = DetectionContext {
        root: Some(root.clone()),
        launcher_path: "/unknown/ports/Test.sh".into(),
        environment: BTreeMap::new(),
        os_release: BTreeMap::new(),
        target_override: None,
    };
    let resolution = config.detect_and_resolve(&loader, &context).unwrap();
    assert_eq!(resolution.platform_id, "generic");
    assert_eq!(resolution.device_class, "unknown-path");
    assert!(!resolution.target_confirmed);
    assert!(!resolution.paths.contains_key("portmaster_core"));

    context.target_override = Some("/custom/PortMaster".into());
    let resolution = config.detect_and_resolve(&loader, &context).unwrap();
    assert_eq!(resolution.device_class, "unsupported-known");
    assert!(resolution.target_confirmed);
    assert_eq!(
        resolution.paths["portmaster_core"],
        root.join("custom/PortMaster")
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn health_rules_are_finite_and_report_damage_without_running_code() {
    let loader = ConfigLoader::default();
    let config = platform_config("generic");
    let root = std::env::temp_dir().join(format!("portkit-health-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("custom/PortMaster/pylibs")).unwrap();
    let context = DetectionContext {
        root: Some(root.clone()),
        launcher_path: "/unknown/ports/Test.sh".into(),
        environment: BTreeMap::new(),
        os_release: BTreeMap::new(),
        target_override: Some("/custom/PortMaster".into()),
    };
    let mut resolution = config.detect_and_resolve(&loader, &context).unwrap();
    let report = evaluate_health(&resolution).unwrap();
    assert_eq!(report.status, HealthStatus::Damaged);

    let core = root.join("custom/PortMaster");
    std::fs::write(core.join("control.txt"), "control").unwrap();
    std::fs::write(core.join("pugwash"), "helper").unwrap();
    std::fs::write(core.join("pylibs/module"), "module").unwrap();
    let executable = core.join("PortMaster.sh");
    std::fs::write(&executable, "#!/bin/sh\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = std::fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&executable, permissions).unwrap();
    }
    resolution.health.push(serde_json::json!({
        "kind": "executable_file", "path": "{portmaster_core}/PortMaster.sh"
    }));
    let report = evaluate_health(&resolution).unwrap();
    assert_eq!(report.status, HealthStatus::Healthy);
    assert!(report.healthy);
    assert!(!report.python_imports.is_empty());

    resolution.python["imports"] = serde_json::json!(["sys;__import__('os')"]);
    assert!(evaluate_health(&resolution).is_err());

    resolution
        .health
        .push(serde_json::json!({"kind": "run_shell"}));
    assert!(evaluate_health(&resolution).is_err());
    let _ = std::fs::remove_dir_all(root);
}

fn rocknix_context() -> DetectionContext {
    DetectionContext {
        root: Some(
            std::env::temp_dir().join(format!("portkit-rocknix-test-{}", std::process::id())),
        ),
        launcher_path: "/storage/roms/ports/Test.sh".into(),
        environment: BTreeMap::new(),
        os_release: BTreeMap::from([("OS_NAME".into(), "ROCKNIX".into())]),
        target_override: None,
    }
}
