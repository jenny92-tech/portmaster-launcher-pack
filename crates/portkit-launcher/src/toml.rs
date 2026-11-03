// INPUT:  toml_edit、serde_json、已有 TOML 文件与 atomic_write()
// OUTPUT: merge_file()；保留格式的有类型 TOML 合并，null 删除指定键
// POS:    在启动器指定文件中原子修改结构化配置，不按文本位置猜测配置层级
use std::io;
use std::path::Path;

use serde_json::Value as Json;
use toml_edit::{Array, ArrayOfTables, DocumentMut, InlineTable, Item, Table, Value};

pub fn merge_file(path: &Path, patch: &Json) -> io::Result<()> {
    let mut document = read_document(path)?;
    apply_patch(&mut document, patch)?;
    write_document(path, &document)
}

pub(crate) fn read_document(path: &Path) -> io::Result<DocumentMut> {
    std::fs::read_to_string(path)?
        .parse()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

pub(crate) fn write_document(path: &Path, document: &DocumentMut) -> io::Result<()> {
    let contents = document.to_string();
    // Parsing the result also guards mistakes when mixing inline tables,
    // dotted keys and array-of-table edits. No partial file is published.
    contents
        .parse::<DocumentMut>()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    crate::atomic::atomic_write(path, contents.as_bytes())
}

pub(crate) fn apply_patch(document: &mut DocumentMut, patch: &Json) -> io::Result<()> {
    if !patch.is_object() {
        return Err(invalid("TOML patch must be a JSON object"));
    }
    merge_item(document.as_item_mut(), patch)
}

fn merge_item(destination: &mut Item, patch: &Json) -> io::Result<()> {
    if let Json::Object(fields) = patch {
        if destination.is_none() {
            if fields.values().all(Json::is_null) {
                return Ok(());
            }
            *destination = Item::Table(Table::new());
        }
        let table = destination
            .as_table_like_mut()
            .ok_or_else(|| invalid("cannot merge a TOML table into a non-table value"))?;
        for (key, value) in fields {
            if value.is_null() {
                table.remove(key);
            } else if let Some(existing) = table.get_mut(key) {
                merge_item(existing, value)?;
            } else {
                let mut item = Item::None;
                merge_item(&mut item, value)?;
                table.insert(key, item);
            }
        }
    } else {
        let mut replacement = if let Json::Array(values) = patch {
            if !values.is_empty() && values.iter().all(Json::is_object) {
                let mut array = ArrayOfTables::new();
                for value in values {
                    let mut item = Item::Table(Table::new());
                    merge_item(&mut item, value)?;
                    array.push(item.into_table().map_err(|_| invalid("invalid table"))?);
                }
                Item::ArrayOfTables(array)
            } else {
                Item::Value(json_value(patch)?)
            }
        } else {
            Item::Value(json_value(patch)?)
        };
        if let (Some(old), Some(new)) = (destination.as_value(), replacement.as_value_mut()) {
            *new.decor_mut() = old.decor().clone();
        }
        *destination = replacement;
    }
    Ok(())
}

fn json_value(value: &Json) -> io::Result<Value> {
    Ok(match value {
        Json::Bool(value) => Value::from(*value),
        Json::String(value) => Value::from(value.as_str()),
        Json::Number(value) if value.is_i64() => Value::from(value.as_i64().unwrap()),
        Json::Number(value) if value.is_u64() => {
            return Err(invalid("integer exceeds the TOML signed 64-bit range"));
        }
        Json::Number(value) => {
            Value::from(value.as_f64().ok_or_else(|| invalid("invalid number"))?)
        }
        Json::Array(values) => {
            let mut array = Array::new();
            for value in values {
                array.push(json_value(value)?);
            }
            Value::Array(array)
        }
        Json::Object(fields) => {
            let mut table = InlineTable::new();
            for (key, value) in fields {
                table.insert(key, json_value(value)?);
            }
            Value::InlineTable(table)
        }
        Json::Null => return Err(invalid("null is only valid to delete a named TOML key")),
    })
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
