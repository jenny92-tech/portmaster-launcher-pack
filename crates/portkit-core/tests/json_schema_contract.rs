use std::fs;
use std::path::{Path, PathBuf};

use jsonschema::{Draft, Registry};
use serde_json::Value;

fn config_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(
        &fs::read(path).unwrap_or_else(|error| panic!("read {}: {error}", path.display())),
    )
    .unwrap_or_else(|error| panic!("parse {}: {error}", path.display()))
}

#[test]
fn generated_root_and_every_platform_detail_pass_draft_2020_12() {
    let config = config_dir();
    let root_schema = read_json(&config.join("appmanager-config.schema.json"));
    let root = read_json(&config.join("config.json"));
    let root_validator = jsonschema::options()
        .with_draft(Draft::Draft202012)
        .build(&root_schema)
        .expect("compile APP Manager root schema");
    let root_errors = root_validator
        .iter_errors(&root)
        .map(|error| error.to_string())
        .collect::<Vec<_>>();
    assert!(
        root_errors.is_empty(),
        "root schema errors: {root_errors:#?}"
    );

    let root_id = root_schema["$id"]
        .as_str()
        .expect("root schema has $id")
        .to_owned();
    let registry = Registry::new()
        .add(&root_id, root_schema.clone())
        .expect("register root schema")
        .prepare()
        .expect("prepare schema registry");
    let detail_schema = read_json(&config.join("platform-detail.schema.json"));
    let detail_validator = jsonschema::options()
        .with_draft(Draft::Draft202012)
        .with_registry(&registry)
        .build(&detail_schema)
        .expect("compile platform detail schema");

    let mut details = fs::read_dir(config.join("platforms"))
        .expect("read generated platform details")
        .map(Result::unwrap)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .collect::<Vec<_>>();
    details.sort();
    assert!(!details.is_empty());
    for path in details {
        let detail = read_json(&path);
        let errors = detail_validator
            .iter_errors(&detail)
            .map(|error| error.to_string())
            .collect::<Vec<_>>();
        assert!(errors.is_empty(), "{}: {errors:#?}", path.display());
    }
}

#[test]
fn schema_rejects_wrong_predicate_types_and_incomplete_health_variants() {
    let config = config_dir();
    let root_schema = read_json(&config.join("appmanager-config.schema.json"));
    let root_id = root_schema["$id"]
        .as_str()
        .expect("root schema has $id")
        .to_owned();
    let registry = Registry::new()
        .add(&root_id, root_schema)
        .expect("register root schema")
        .prepare()
        .expect("prepare schema registry");
    let detail_schema = read_json(&config.join("platform-detail.schema.json"));
    let validator = jsonschema::options()
        .with_draft(Draft::Draft202012)
        .with_registry(&registry)
        .build(&detail_schema)
        .expect("compile platform detail schema");
    let mut detail = read_json(&config.join("platforms/generic.json"));

    detail["health"] = serde_json::json!([{"kind": "required_file"}]);
    assert!(!validator.is_valid(&detail));

    let mut detail = read_json(&config.join("platforms/generic.json"));
    detail["recognition"] = serde_json::json!({
        "kind": "file_exists",
        "path": "/etc/os-release",
        "case_insensitive": "yes"
    });
    assert!(!validator.is_valid(&detail));
}
