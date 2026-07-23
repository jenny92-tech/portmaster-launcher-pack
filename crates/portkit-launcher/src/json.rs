use std::io;
use std::path::Path;

use serde_json::{Map, Value};

pub fn merge_file(path: &Path, patch: &Value) -> io::Result<()> {
    if !patch.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "JSON merge patch must be an object",
        ));
    }
    let mut value = if path.is_file() {
        let bytes = std::fs::read(path)?;
        serde_json::from_slice(&bytes).map_err(invalid_data)?
    } else {
        Value::Object(Map::new())
    };
    if !value.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "existing JSON root must be an object",
        ));
    }
    merge(&mut value, patch);
    let mut bytes = serde_json::to_vec_pretty(&value).map_err(invalid_data)?;
    bytes.push(b'\n');
    portkit_core::atomic_write(path, &bytes)
}

/// Recursively merges `patch` into `target`.
///
/// This is a deep merge, **not** RFC 7396 JSON Merge Patch: a `null` in the
/// patch is written as an ordinary value and never deletes a key. Objects are
/// merged key by key; any non-object patch value replaces the target value
/// outright. Current callers (patches generated from the ports'
/// `launcher.sh.template`) never need to delete keys, so no deletion
/// semantics are required.
fn merge(target: &mut Value, patch: &Value) {
    let (Some(target), Some(patch)) = (target.as_object_mut(), patch.as_object()) else {
        *target = patch.clone();
        return;
    };
    for (key, patch_value) in patch {
        if let Some(target_value) = target.get_mut(key)
            && target_value.is_object()
            && patch_value.is_object()
        {
            merge(target_value, patch_value);
        } else {
            target.insert(key.clone(), patch_value.clone());
        }
    }
}

fn invalid_data(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}
