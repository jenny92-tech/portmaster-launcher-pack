use std::io;
use std::path::PathBuf;

pub struct ConfigureRequest {
    pub path: PathBuf,
    /// Table to write into, e.g. `device`. `None` is the root table (the keys
    /// above the first header). Which table a key belongs to is the reader's
    /// contract, so the caller names it.
    pub section: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub buttons: Option<[String; 4]>,
    /// Internal Unity render percentage. This always belongs to `[gpu]`,
    /// independently of the table selected for display or input settings.
    pub render_scale_percent: Option<u32>,
}

pub fn configure(request: &ConfigureRequest) -> io::Result<()> {
    if request
        .render_scale_percent
        .is_some_and(|value| !matches!(value, 100 | 75 | 50))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "render scale percent must be 100, 75 or 50",
        ));
    }
    let contents = std::fs::read_to_string(&request.path)?;
    let mut lines: Vec<String> = contents.lines().map(str::to_owned).collect();
    let section = request.section.as_deref();
    if let Some(width) = request.width {
        let value = width.to_string();
        upsert(
            &mut lines,
            section,
            "displayWidth",
            format!("displayWidth={value}"),
        );
    }
    if let Some(height) = request.height {
        let value = height.to_string();
        upsert(
            &mut lines,
            section,
            "displayHeight",
            format!("displayHeight={value}"),
        );
    }
    if let Some(buttons) = &request.buttons {
        upsert_section(
            &mut lines,
            section.unwrap_or_default(),
            &[
                ("a", format!("\"{}\"", buttons[0])),
                ("b", format!("\"{}\"", buttons[1])),
                ("x", format!("\"{}\"", buttons[2])),
                ("y", format!("\"{}\"", buttons[3])),
            ],
        );
    }
    if let Some(percent) = request.render_scale_percent {
        upsert(
            &mut lines,
            Some("gpu"),
            "renderScalePercent",
            format!("renderScalePercent = {percent}"),
        );
        upsert(
            &mut lines,
            Some("gpu"),
            "renderScaleSharp",
            "renderScaleSharp = true".to_owned(),
        );
        // An exact pair takes precedence in Bogodroid. Reset it whenever the
        // launcher selects a scale so stale manual values cannot win silently.
        upsert(
            &mut lines,
            Some("gpu"),
            "renderWidth",
            "renderWidth = 0".to_owned(),
        );
        upsert(
            &mut lines,
            Some("gpu"),
            "renderHeight",
            "renderHeight = 0".to_owned(),
        );
        remove_all(&mut lines, Some("gpu"), "renderScaleDivisor");
        remove_all(&mut lines, Some("gpu"), "renderScaleLinear");
    }
    let mut output = lines.join("\n");
    output.push('\n');
    crate::atomic::atomic_write(&request.path, output.as_bytes())
}

/// Sets `key` in `section`, creating the section if absent. Inserts only when
/// the table holds no copy, so it can never define a key twice — which the
/// loader's toml++ rejects outright, aborting on startup. Other tables are left
/// alone: the same name under another header is a different toml key.
fn upsert(lines: &mut Vec<String>, section: Option<&str>, key: &str, rendered: String) {
    let (start, insert_at) = match section {
        None => (0, first_section(lines, 0)),
        Some(name) => {
            let header = format!("[{name}]");
            let index = match lines.iter().position(|line| line.trim() == header) {
                Some(index) => index,
                None => {
                    if lines.last().is_some_and(|line| !line.is_empty()) {
                        lines.push(String::new());
                    }
                    lines.push(header);
                    lines.len() - 1
                }
            };
            (index + 1, index + 1)
        }
    };
    let end = match section {
        None => insert_at,
        Some(_) => first_section(lines, start),
    };
    if !rewrite_all(lines, start, end, key, &rendered) {
        lines.insert(insert_at, rendered);
    }
}

/// Index of the first section header at or after `from`, else the line count.
fn first_section(lines: &[String], from: usize) -> usize {
    lines[from..]
        .iter()
        .position(|line| line.trim_start().starts_with('['))
        .map_or(lines.len(), |offset| from + offset)
}

/// Rewrites every match in the range, not just the first, so no copy is left
/// holding a stale value. In place only — a line keeps its position next to
/// whatever comment documents it. Returns whether the key was there at all.
fn rewrite_all(lines: &mut [String], start: usize, end: usize, key: &str, rendered: &str) -> bool {
    let mut found = false;
    for line in &mut lines[start..end] {
        if line_key(line.trim_start()) == Some(key) {
            *line = rendered.to_owned();
            found = true;
        }
    }
    found
}

fn remove_all(lines: &mut Vec<String>, section: Option<&str>, key: &str) {
    let start = match section {
        None => 0,
        Some(name) => {
            let header = format!("[{name}]");
            let Some(index) = lines.iter().position(|line| line.trim() == header) else {
                return;
            };
            index + 1
        }
    };
    let end = first_section(lines, start);
    for index in (start..end).rev() {
        if line_key(lines[index].trim_start()) == Some(key) {
            lines.remove(index);
        }
    }
}

fn upsert_section(lines: &mut Vec<String>, section: &str, values: &[(&str, String)]) {
    let header = format!("[{section}]");
    let Some(start) = lines.iter().position(|line| line.trim() == header) else {
        if lines.last().is_some_and(|line| !line.is_empty()) {
            lines.push(String::new());
        }
        lines.push(header);
        for (key, value) in values {
            lines.push(format!("{key:<8}= {value}"));
        }
        return;
    };
    let end = lines[start + 1..]
        .iter()
        .position(|line| line.trim_start().starts_with('['))
        .map_or(lines.len(), |offset| start + 1 + offset);
    for index in (start + 1..end).rev() {
        if values
            .iter()
            .any(|(key, _)| line_key(&lines[index]) == Some(key))
        {
            lines.remove(index);
        }
    }
    for (offset, (key, value)) in values.iter().enumerate() {
        lines.insert(start + 1 + offset, format!("{key:<8}= {value}"));
    }
}

fn line_key(line: &str) -> Option<&str> {
    let (key, _) = line.split_once('=')?;
    Some(key.trim())
}
