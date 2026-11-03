// INPUT:  selected Android graphics API and parsed per-game TOML
// OUTPUT: atomic backend/filter configuration and Unity startup argument edits
// POS:    keeps backend/filter selection atomic without changing resolution or GLES settings
#![forbid(unsafe_code)]
use serde_json::json;
use std::io;
use toml_edit::DocumentMut;

pub(crate) fn configure_filter(document: &mut DocumentMut, filter: &str) -> io::Result<()> {
    if !matches!(filter, "config" | "linear" | "sharp") {
        return Err(invalid("render filter must be config, linear or sharp"));
    }
    let api = document
        .get("gpu")
        .and_then(|v| v.as_table_like())
        .and_then(|v| v.get("graphicsApi"));
    let api = match api {
        None => "gles",
        Some(value) => value
            .as_str()
            .ok_or_else(|| invalid("gpu.graphicsApi must be a string"))?,
    };
    match api {
        "vulkan" if filter == "sharp" => Err(invalid("Vulkan supports linear render scaling only")),
        "vulkan" => {
            crate::toml::apply_patch(document, &json!({"gpu":{"vulkanRenderFilter":"linear"}}))
        }
        "gles" if filter == "config" => Ok(()),
        "gles" => crate::toml::apply_patch(
            document,
            &json!({"gpu":{"renderScaleSharp":filter=="sharp"}}),
        ),
        _ => Err(invalid("gpu.graphicsApi must be gles or vulkan")),
    }
}

pub(crate) fn configure(document: &mut DocumentMut, selection: &str) -> io::Result<()> {
    let (api, argument) = match selection {
        "gles" => ("gles", None),
        "gles30" => ("gles", Some("-force-gles30")),
        "gles32" => ("gles", Some("-force-gles32")),
        "vulkan" => ("vulkan", Some("-force-vulkan")),
        _ => {
            return Err(invalid(
                "graphics API must be gles, gles30, gles32 or vulkan",
            ));
        }
    };
    let arguments = document
        .get("package")
        .and_then(|v| v.as_table_like())
        .and_then(|v| v.get("mainIntentBundle"))
        .and_then(|v| v.as_table_like())
        .and_then(|v| v.get("unity"));
    let arguments = match arguments {
        None => "",
        Some(v) => v
            .as_str()
            .ok_or_else(|| invalid("package.mainIntentBundle.unity must be a string"))?,
    };
    let arguments = replace_api(arguments, argument)?;
    if api == "vulkan" {
        if let Some(gpu) = document.get("gpu").and_then(|v| v.as_table_like()) {
            if gpu
                .get("renderScaleDivisor")
                .is_some_and(|v| v.as_integer() != Some(1))
            {
                return Err(invalid(
                    "Vulkan needs renderScalePercent or exact dimensions; legacy renderScaleDivisor is unsupported",
                ));
            }
            if gpu
                .get("vulkanRenderFilter")
                .is_some_and(|v| v.as_str() != Some("linear"))
            {
                return Err(invalid("Vulkan supports linear render scaling only"));
            }
            if gpu
                .get("presentationBackend")
                .is_some_and(|v| v.as_str() != Some("internal"))
            {
                return Err(invalid("Vulkan requires internal presentation"));
            }
        }
    }
    crate::toml::apply_patch(
        document,
        &json!({"gpu":{"graphicsApi":api},
        "package":{"mainIntentBundle":{"unity":arguments}}}),
    )?;
    if api == "vulkan" {
        crate::toml::apply_patch(document, &json!({"gpu":{"vulkanRenderFilter":"linear"}}))?;
    }
    Ok(())
}

// Retain each unrelated argument verbatim, including whitespace inside quotes.
// Do not replace flag-shaped text inside another argument or quoted value.
fn replace_api(input: &str, argument: Option<&str>) -> io::Result<String> {
    if input.len() > 65536 || input.contains('\0') {
        return Err(invalid("invalid Unity startup arguments"));
    }
    let mut retained = Vec::new();
    let mut start = None;
    let mut decoded = String::new();
    let mut quote = None;
    let mut escaped = false;
    for (offset, ch) in input
        .char_indices()
        .chain(std::iter::once((input.len(), ' ')))
    {
        if offset == input.len() && (quote.is_some() || escaped) {
            return Err(invalid(
                "unclosed quote or escape in Unity startup arguments",
            ));
        }
        if escaped {
            decoded.push(ch);
            escaped = false;
            continue;
        }
        if ch == '\\' && quote != Some('\'') {
            start.get_or_insert(offset);
            escaped = true;
            continue;
        }
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            } else {
                decoded.push(ch);
            }
        } else if ch == '\'' || ch == '"' {
            start.get_or_insert(offset);
            quote = Some(ch);
        } else if ch.is_ascii_whitespace() {
            if let Some(begin) = start.take() {
                let graphics_flag = matches!(
                    decoded.as_str(),
                    "-force-vulkan"
                        | "-force-gles"
                        | "-force-gles20"
                        | "-force-gles30"
                        | "-force-gles31"
                        | "-force-gles31aep"
                        | "-force-gles32"
                );
                if !graphics_flag || (argument.is_none() && decoded != "-force-vulkan") {
                    retained.push(&input[begin..offset]);
                }
                decoded.clear();
            }
        } else {
            start.get_or_insert(offset);
            decoded.push(ch);
        }
    }
    if let Some(argument) = argument {
        retained.push(argument);
    }
    Ok(retained.join(" "))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
