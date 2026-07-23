use std::io;
use std::path::PathBuf;

pub struct ConfigureRequest {
    pub path: PathBuf,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub buttons: Option<[String; 4]>,
}

pub fn configure(request: &ConfigureRequest) -> io::Result<()> {
    let contents = std::fs::read_to_string(&request.path)?;
    let mut lines: Vec<String> = contents.lines().map(str::to_owned).collect();
    if let Some(width) = request.width {
        upsert_root(&mut lines, "displayWidth", &width.to_string());
    }
    if let Some(height) = request.height {
        upsert_root(&mut lines, "displayHeight", &height.to_string());
    }
    if let Some(buttons) = &request.buttons {
        upsert_section(
            &mut lines,
            "input.remap",
            &[
                ("a", format!("\"{}\"", buttons[0])),
                ("b", format!("\"{}\"", buttons[1])),
                ("x", format!("\"{}\"", buttons[2])),
                ("y", format!("\"{}\"", buttons[3])),
            ],
        );
    }
    let mut output = lines.join("\n");
    output.push('\n');
    portkit_core::atomic_write(&request.path, output.as_bytes())
}

fn upsert_root(lines: &mut Vec<String>, key: &str, value: &str) {
    let mut section_seen = false;
    for line in lines.iter_mut() {
        let trimmed = line.trim_start();
        if trimmed.starts_with('[') {
            section_seen = true;
        }
        if !section_seen && line_key(trimmed) == Some(key) {
            *line = format!("{key}={value}");
            return;
        }
    }
    let index = lines
        .iter()
        .position(|line| line.trim_start().starts_with('['))
        .unwrap_or(lines.len());
    lines.insert(index, format!("{key}={value}"));
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
