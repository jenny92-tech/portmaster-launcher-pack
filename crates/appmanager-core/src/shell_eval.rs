// INPUT:  Bash AST、显式 SourceEnvironment 和变量
// OUTPUT: shell_paths::PathAnalysis
// POS:    有界抽象求值与语法缓存；结构证明纯等待不污染路径，不执行 Shell 命令

use crate::shell_paths::PathAnalysis;
use crate::shell_sources::SourceEnvironment;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use tree_sitter::{Node, Parser};

const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_VALUE: usize = 4096;
const MAX_ITEMS: usize = 2048;
const MAX_STEPS: usize = 200_000;
const MAX_DEPTH: usize = 64;

// Cache syntax only, keyed by the exact current contents. Never cache evaluated
// variables, branches, filesystem facts or source-read failures across scans.
thread_local! {
    static SYNTAX_CACHE: std::cell::RefCell<SyntaxCache> = std::cell::RefCell::new(SyntaxCache::default());
}
#[derive(Default)]
struct SyntaxCache {
    trees: std::collections::VecDeque<(String, tree_sitter::Tree, usize)>,
    bytes: usize,
}
impl SyntaxCache {
    fn parse(&mut self, source: &str) -> Option<tree_sitter::Tree> {
        if let Some(index) = self.trees.iter().position(|(text, _, _)| text == source) {
            let entry = self.trees.remove(index).unwrap();
            let tree = entry.1.clone();
            self.trees.push_back(entry);
            return Some(tree);
        }
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_bash::LANGUAGE.into())
            .ok()?;
        #[allow(deprecated)]
        parser.set_timeout_micros(100_000);
        let tree = parser.parse(source, None)?;
        // Approximate node storage as well as source text; bound both entries and
        // estimated memory, even for scripts with very dense syntax trees.
        let cost = source
            .len()
            .saturating_add(tree.root_node().descendant_count().saturating_mul(128));
        const CACHE_BYTES: usize = 8 * 1024 * 1024;
        if cost <= CACHE_BYTES {
            while self.bytes.saturating_add(cost) > CACHE_BYTES || self.trees.len() >= 128 {
                if let Some((_, _, old_cost)) = self.trees.pop_front() {
                    self.bytes -= old_cost;
                } else {
                    break;
                }
            }
            self.bytes += cost;
            self.trees
                .push_back((source.to_owned(), tree.clone(), cost));
        }
        Some(tree)
    }
}

#[cfg(test)]
mod cache_tests {
    use super::*;

    #[test]
    fn syntax_cache_is_content_keyed_and_bounded() {
        let mut cache = SyntaxCache::default();
        cache.parse("cd /old").unwrap();
        cache.parse("cd /old").unwrap();
        assert_eq!(cache.trees.len(), 1);
        cache.parse("cd /new").unwrap();
        assert_eq!(cache.trees.len(), 2);
        for i in 0..256 {
            cache.parse(&format!("X={i}")).unwrap();
        }
        assert!(cache.trees.len() <= 128);
        assert!(cache.bytes <= 8 * 1024 * 1024);
    }

    #[test]
    fn shared_syntax_never_reuses_evaluated_variables_or_source_contents() {
        use crate::shell_sources::SnapshotEnvironment;
        let mut env = SnapshotEnvironment::default();
        for value in ["/first", "/second"] {
            env.files
                .insert(PathBuf::from("/helper.txt"), format!("GAME={value}"));
            let result = analyze(
                "source /helper.txt\ncd \"$GAME\"",
                &BTreeMap::new(),
                Path::new("/game.sh"),
                &env,
            );
            assert_eq!(result.working_directories, BTreeSet::from([value.into()]));
            let result = analyze(
                "cd \"$GAME\"",
                &BTreeMap::from([("GAME".into(), value.into())]),
                Path::new("/game.sh"),
                &env,
            );
            assert_eq!(result.working_directories, BTreeSet::from([value.into()]));
        }
    }
}
type Value = Option<String>;

#[derive(Clone, Default)]
struct State {
    vars: BTreeMap<String, Value>,
    unset: BTreeSet<String>,
    functions: BTreeMap<String, (Arc<str>, PathBuf)>,
    cwd: Value,
    status: Option<bool>,
    stopped: bool,
    exited: bool,
}

pub(crate) fn analyze(
    source: &str,
    vars: &BTreeMap<String, String>,
    script: &Path,
    environment: &dyn SourceEnvironment,
) -> PathAnalysis {
    let mut engine = Engine {
        source: String::new(),
        file: script.to_owned(),
        environment,
        result: PathAnalysis::default(),
        steps: MAX_STEPS,
        bytes: 0,
        stack: Vec::new(),
        locals: Vec::new(),
        traps: Vec::new(),
        changed_trees: BTreeSet::new(),
    };
    if vars.len() > MAX_ITEMS
        || vars
            .iter()
            .any(|(k, v)| k.len() > MAX_VALUE || v.len() > MAX_VALUE)
    {
        engine.issue("input variable limit");
        return engine.result;
    }
    let mut state = State {
        vars: vars
            .iter()
            .map(|(k, v)| (k.clone(), Some(v.clone())))
            .collect(),
        cwd: script.parent().map(|p| p.to_string_lossy().into_owned()),
        ..Default::default()
    };
    state
        .vars
        .insert("0".into(), Some(script.to_string_lossy().into_owned()));
    engine.run(source, script, &mut state, 0);
    // Traps are potential references too. Inspect handlers once, never invoke
    // real signals or recursively dispatch traps registered by a handler.
    for handler in std::mem::take(&mut engine.traps) {
        let mut child = state.clone();
        child.stopped = false;
        child.exited = false;
        engine.run(&handler, script, &mut child, 0);
    }
    engine.result
}

struct Engine<'a> {
    source: String,
    file: PathBuf,
    environment: &'a dyn SourceEnvironment,
    result: PathAnalysis,
    steps: usize,
    bytes: usize,
    stack: Vec<PathBuf>,
    locals: Vec<BTreeMap<String, Option<Value>>>,
    traps: Vec<String>,
    changed_trees: BTreeSet<String>,
}

impl Engine<'_> {
    fn text(&self, n: Node<'_>) -> &str {
        &self.source[n.byte_range()]
    }
    fn issue(&mut self, s: &str) {
        if self.result.diagnostics.len() < 128 {
            self.result
                .diagnostics
                .insert(format!("{}: {s}", self.file.display()));
        }
    }
    fn note(&mut self, s: &str) {
        if self.result.notes.len() < 128 {
            self.result
                .notes
                .insert(format!("{}: {s}", self.file.display()));
        }
    }
    fn poison(&mut self, state: &mut State, reason: &str) {
        self.issue(reason);
        for value in state.vars.values_mut() {
            *value = None;
        }
        state.cwd = None;
        state.status = None;
        state.unset.clear();
    }
    fn unset_names(&mut self, names: &[Value], state: &mut State) {
        let mut function = false;
        for name in names {
            let Some(name) = name else {
                self.poison(state, "unresolved unset name");
                return;
            };
            if name == "-v" {
                function = false;
                continue;
            }
            if name == "-f" {
                function = true;
                continue;
            }
            if name == "--" {
                continue;
            }
            if name.is_empty() || !name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_') {
                self.poison(state, "unsupported unset target");
                return;
            }
            if function {
                state.functions.remove(name);
            } else {
                state.vars.insert(name.clone(), Some(String::new()));
                state.unset.insert(name.clone());
            }
        }
        state.status = Some(true);
    }
    fn changed(&self, path: &Path) -> bool {
        self.result
            .output_paths
            .contains(&path.to_string_lossy().into_owned())
            || self.changed_trees.iter().any(|p| path.starts_with(p))
    }
    fn path_template(&self, node: Node<'_>) -> bool {
        match node.kind() {
            "word" | "string_content" | "raw_string" => self.text(node).contains('/'),
            "string" | "concatenation" | "expansion" => {
                let mut c = node.walk();
                node.named_children(&mut c).any(|n| self.path_template(n))
            }
            _ => false,
        }
    }
    fn case_match(
        &mut self,
        node: Node<'_>,
        value: &str,
        state: &State,
        depth: usize,
    ) -> Option<bool> {
        if node.kind() == "word" && !self.text(node).contains('\\') {
            let raw = self.text(node);
            if raw == "*" {
                return Some(true);
            }
            if let Some((prefix, suffix)) = raw.split_once('*') {
                if !suffix.contains('*') && !raw.contains(['?', '[']) {
                    return Some(
                        value.len() >= prefix.len() + suffix.len()
                            && value.starts_with(prefix)
                            && value.ends_with(suffix),
                    );
                }
            }
        }
        if node.kind() == "concatenation" {
            let mut c = node.walk();
            let parts = node.named_children(&mut c).collect::<Vec<_>>();
            if parts
                .last()
                .is_some_and(|n| n.kind() == "word" && self.text(*n) == "*")
            {
                let prefix = parts[..parts.len() - 1]
                    .iter()
                    .map(|n| self.word(*n, state, depth + 1))
                    .collect::<Option<Vec<_>>>()?
                    .concat();
                return Some(value.starts_with(&prefix));
            }
        }
        let p = self.word(node, state, depth + 1)?;
        if !matches!(node.kind(), "string" | "raw_string") && p.contains(['*', '?', '[']) {
            return None;
        }
        Some(p == value)
    }
    fn budget(&mut self, d: usize) -> bool {
        if self.steps == 0 || d > MAX_DEPTH {
            self.issue("analysis budget exhausted");
            false
        } else {
            self.steps -= 1;
            true
        }
    }
    fn run(&mut self, source: &str, file: &Path, state: &mut State, depth: usize) {
        self.bytes = self.bytes.saturating_add(source.len());
        if self.bytes > MAX_BYTES || !self.budget(depth) {
            self.issue("source byte/depth limit");
            return;
        }
        let Some(tree) = SYNTAX_CACHE.with(|cache| cache.borrow_mut().parse(source)) else {
            self.issue("parse limit");
            return;
        };
        let old_source = std::mem::replace(&mut self.source, source.into());
        let old_file = std::mem::replace(&mut self.file, file.to_owned());
        if tree.root_node().has_error() {
            self.issue("invalid or unsupported Shell syntax");
        }
        let old_bash = state.vars.insert(
            "BASH_SOURCE".into(),
            Some(file.to_string_lossy().into_owned()),
        );
        self.statement(tree.root_node(), state, depth + 1);
        if let Some(v) = old_bash {
            state.vars.insert("BASH_SOURCE".into(), v);
        } else {
            state.vars.remove("BASH_SOURCE");
        }
        self.source = old_source;
        self.file = old_file;
    }
    fn absolute(&mut self, value: &str, state: &State) -> Value {
        if value.len() > MAX_VALUE || value.contains('\0') {
            self.issue("path size/encoding limit");
            return None;
        }
        let path = if value.starts_with('/') {
            PathBuf::from(value)
        } else {
            Path::new(state.cwd.as_ref()?).join(value)
        };
        if path.components().any(|c| matches!(c, Component::ParentDir)) {
            return self
                .environment
                .canonicalize(&path)
                .map(|p| p.to_string_lossy().into_owned());
        }
        Some(
            path.components()
                .collect::<PathBuf>()
                .to_string_lossy()
                .into_owned(),
        )
    }
    fn record(&mut self, value: &str, state: &State, kind: &str) -> Value {
        if self.result.paths.len() >= MAX_ITEMS || self.result.output_paths.len() >= MAX_ITEMS {
            self.issue("path count limit");
            return None;
        }
        if value.contains("://") || value.starts_with("rgbi:") {
            return None;
        }
        // Java classpaths and other colon-separated absolute search paths can
        // reach commands through arbitrarily named variables.
        if kind == "argument" && value.contains(':') {
            for part in value.split(':').filter(|part| part.starts_with('/')) {
                self.record(part, state, kind);
            }
            // Keep the unsplit candidate too: ':' is legal in a filename, and
            // path-list inference must never hide a directory from cleanup.
        }
        if kind == "argument"
            && !(value.starts_with('/') || value.starts_with("./") || value.starts_with("../"))
        {
            return None;
        }
        let Some(path) = self.absolute(value, state) else {
            self.issue("unresolved path base or symlink parent");
            return None;
        };
        match kind {
            "library" => {
                self.result.library_paths.insert(path.clone());
            }
            "preload" => {
                self.result.preload_libraries.insert(path.clone());
            }
            "input" => {
                self.result.input_configs.insert(path.clone());
            }
            "output" => {
                self.result.output_paths.insert(path.clone());
                return Some(path);
            }
            "cwd" => {
                self.result.working_directories.insert(path.clone());
            }
            _ => (),
        }
        self.result.paths.insert(path.clone());
        Some(path)
    }
    fn list_paths(&mut self, name: &str, value: &str, state: &State) {
        if name == "LD_LIBRARY_PATH" {
            for part in value.split(':') {
                self.record(if part.is_empty() { "." } else { part }, state, "library");
            }
        } else if name == "LD_PRELOAD" {
            for part in value
                .split(|c: char| c == ':' || c.is_ascii_whitespace())
                .filter(|v| !v.is_empty())
            {
                if part.contains('/') {
                    self.record(part, state, "preload");
                } else {
                    if self.result.preload_libraries.len() >= MAX_ITEMS {
                        self.issue("preload count limit");
                        return;
                    }
                    self.result.preload_libraries.insert(part.into());
                }
            }
        } else if matches!(name, "SDL_GAMECONTROLLERCONFIG_FILE" | "GPTOKEYB_CONFIG") {
            self.record(value, state, "input");
        }
    }
    fn runtime_name(&mut self, value: &str) {
        let name = value.trim_start_matches('/');
        let name = name.strip_suffix(".squashfs").unwrap_or(name);
        if !name.is_empty()
            && !name.starts_with('.')
            && !name.contains("..")
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'+' | b'-'))
            && !self.result.runtime_names.iter().any(|v| v == name)
        {
            if self.result.runtime_names.len() < MAX_ITEMS {
                self.result.runtime_names.push(name.into());
            } else {
                self.issue("runtime count limit");
            }
        }
    }
    fn word(&mut self, node: Node<'_>, state: &State, depth: usize) -> Value {
        if !self.budget(depth) {
            return None;
        }
        match node.kind() {
            "word" | "string_content" | "number" | "variable_name" => {
                let text = self.text(node);
                if node.kind() == "word" && text.chars().any(|c| matches!(c, '*' | '?' | '[' | '{'))
                {
                    return None;
                }
                if text == "~" {
                    return state.vars.get("HOME").cloned().flatten();
                }
                if let Some(rest) = text.strip_prefix("~/") {
                    return state
                        .vars
                        .get("HOME")
                        .cloned()
                        .flatten()
                        .map(|v| format!("{v}/{rest}"));
                }
                Some(unescape(text, node.kind() == "string_content"))
            }
            "raw_string" => Some(
                self.text(node)
                    .strip_prefix('\'')?
                    .strip_suffix('\'')?
                    .into(),
            ),
            "simple_expansion" => {
                let name = self.text(node).trim_start().strip_prefix('$')?;
                if name == "?" {
                    return state.status.map(|v| if v { "0" } else { "1" }.into());
                }
                if name == "PWD" {
                    return state.cwd.clone();
                }
                state.vars.get(name).cloned().flatten()
            }
            "expansion" => {
                let name = node.named_child(0)?;
                let key = if name.kind() == "subscript" {
                    let base = name.child_by_field_name("name")?;
                    let index = name.child_by_field_name("index")?;
                    if self.text(base) == "BASH_SOURCE" && self.text(index) == "0" {
                        "BASH_SOURCE".to_owned()
                    } else {
                        return None;
                    }
                } else {
                    self.text(name).to_owned()
                };
                let value = if key == "PWD" {
                    state.cwd.clone()
                } else {
                    state.vars.get(&key).cloned().flatten()
                };
                let Some(op) = node.child_by_field_name("operator") else {
                    return value;
                };
                match self.text(op) {
                    ":-" | "-" => {
                        let Some(v) = value else {
                            let _ = self.word(node.named_child(1)?, state, depth + 1);
                            return None;
                        };
                        if !state.unset.contains(&key) && (self.text(op) == "-" || !v.is_empty()) {
                            Some(v)
                        } else {
                            self.word(node.named_child(1)?, state, depth + 1)
                        }
                    }
                    "+" | ":+" => {
                        let Some(v) = value else {
                            let _ = self.word(node.named_child(1)?, state, depth + 1);
                            return None;
                        };
                        if state.unset.contains(&key) || (self.text(op) == ":+" && v.is_empty()) {
                            Some(String::new())
                        } else {
                            self.word(node.named_child(1)?, state, depth + 1)
                        }
                    }
                    "%" | "%%" => {
                        let n = node.named_child(1)?;
                        let pattern = if self.text(n) == "/*" {
                            "/*".into()
                        } else {
                            self.word(n, state, depth + 1)?
                        };
                        let v = value?;
                        if pattern == "/*" {
                            let split = if self.text(op) == "%%" {
                                v.split_once('/')
                            } else {
                                v.rsplit_once('/')
                            };
                            return Some(split.map_or(v.as_str(), |x| x.0).into());
                        }
                        if pattern.starts_with('*') {
                            return None;
                        }
                        Some(v.strip_suffix(&pattern).unwrap_or(&v).into())
                    }
                    _ => {
                        self.issue("parameter expansion operator unsupported");
                        None
                    }
                }
            }
            "string" | "concatenation" => {
                let mut out = String::new();
                let mut c = node.walk();
                let mut known = true;
                let quoted = node.kind() == "string";
                let mut offset = node.start_byte() + usize::from(quoted);
                for child in node.named_children(&mut c) {
                    out.push_str(&unescape(&self.source[offset..child.start_byte()], quoted));
                    // Bash's external scanner can include leading literal spaces
                    // in an expansion node inside quotes (e.g. "$A $B").
                    if quoted
                        && matches!(
                            child.kind(),
                            "simple_expansion" | "expansion" | "command_substitution"
                        )
                    {
                        let text = self.text(child);
                        out.push_str(&text[..text.len() - text.trim_start().len()]);
                    }
                    let part = self.word(child, state, depth + 1);
                    known &= part.is_some();
                    let part = part.unwrap_or_default();
                    if out.len() + part.len() > MAX_VALUE {
                        self.issue("expansion size limit");
                        return None;
                    }
                    out.push_str(&part);
                    offset = child.end_byte();
                }
                out.push_str(&unescape(
                    &self.source[offset..node.end_byte() - usize::from(quoted)],
                    quoted,
                ));
                known.then_some(out)
            }
            "command_name" => self.word(node.named_child(0)?, state, depth + 1),
            "command_substitution" => {
                let raw = self.text(node).to_owned();
                if let Some(value) = self.environment.command_output(&raw) {
                    return (value.len() <= MAX_VALUE).then_some(value);
                }
                let mut child = state.clone();
                let mut c = node.walk();
                for command in node.named_children(&mut c) {
                    self.statement(command, &mut child, depth + 1);
                }
                if node.named_child_count() != 1 {
                    return None;
                }
                let command = node.named_child(0)?;
                if command.kind() != "command" {
                    return None;
                }
                let mut cursor = command.walk();
                let args = command
                    .named_children(&mut cursor)
                    .map(|n| self.word(n, state, depth + 1))
                    .collect::<Option<Vec<_>>>()?;
                match args.as_slice() {
                    [cmd] if cmd == "pwd" => state.cwd.clone(),
                    [cmd, path] if cmd == "dirname" => Some(
                        Path::new(path)
                            .parent()
                            .filter(|p| !p.as_os_str().is_empty())
                            .unwrap_or(Path::new("."))
                            .to_string_lossy()
                            .into_owned(),
                    ),
                    [cmd, path] if cmd == "basename" => Path::new(path)
                        .file_name()
                        .map(|p| p.to_string_lossy().into_owned()),
                    [cmd, option, path] if cmd == "readlink" && option == "-f" => self
                        .environment
                        .canonicalize(Path::new(path))
                        .map(|p| p.to_string_lossy().into_owned()),
                    [cmd, path] if cmd == "cat" => self
                        .environment
                        .read(Path::new(path))
                        .ok()
                        .filter(|v| v.len() <= MAX_VALUE)
                        .map(|v| v.trim_end_matches('\n').into()),
                    _ => None,
                }
            }
            "arithmetic_expansion" => {
                self.issue("arithmetic expansion is not modeled");
                None
            }
            _ => None,
        }
    }
    fn merge(&mut self, target: &mut State, a: State, b: State) {
        let mut vars = BTreeMap::new();
        for key in a.vars.keys().chain(b.vars.keys()) {
            let av = a.vars.get(key);
            let bv = b.vars.get(key);
            vars.insert(
                key.clone(),
                if av == bv {
                    av.cloned().flatten()
                } else {
                    None
                },
            );
        }
        target.vars = vars;
        target.unset = a.unset.intersection(&b.unset).cloned().collect();
        target.cwd = if a.cwd == b.cwd { a.cwd } else { None };
        if a.functions != b.functions {
            self.issue("conditional function definitions differ");
        }
        target.functions = a
            .functions
            .into_iter()
            .filter(|(k, v)| b.functions.get(k) == Some(v))
            .collect();
        target.status = if a.status == b.status { a.status } else { None };
        target.stopped = a.stopped && b.stopped;
        target.exited = a.exited && b.exited;
    }
    fn condition(&mut self, node: Node<'_>, state: &mut State, depth: usize) -> Option<bool> {
        if !self.budget(depth) {
            return None;
        }
        match node.kind() {
            "test_command" => self.condition(node.named_child(0)?, state, depth + 1),
            "unary_expression" => {
                let mut c = node.walk();
                let children = node.named_children(&mut c).collect::<Vec<_>>();
                let operand = *children.last()?;
                let op = self
                    .text(node)
                    .get(..operand.start_byte() - node.start_byte())?
                    .trim()
                    .to_owned();
                if op == "!" {
                    return self.condition(operand, state, depth + 1).map(|v| !v);
                }
                let value = self.word(operand, state, depth + 1)?;
                match op.as_str() {
                    "-z" => Some(value.is_empty()),
                    "-n" => Some(!value.is_empty()),
                    "-d" | "-f" | "-e" | "-x" | "-L" | "-h" => {
                        if value.is_empty() {
                            return Some(false);
                        }
                        let path = self.absolute(&value, state)?;
                        if self.changed(Path::new(&path)) {
                            return None;
                        }
                        self.environment.test(Path::new(&path), &op)
                    }
                    _ => None,
                }
            }
            "binary_expression" => {
                let left = node.child_by_field_name("left")?;
                let right = node.child_by_field_name("right")?;
                let op = self.source[left.end_byte()..right.start_byte()]
                    .trim()
                    .to_owned();
                if op == "&&" || op == "||" {
                    return self.logical(left, right, &op, state, depth + 1);
                }
                let a = self.word(left, state, depth + 1)?;
                let b = self.word(right, state, depth + 1)?;
                match op.as_str() {
                    "=" | "==" => Some(a == b),
                    "!=" => Some(a != b),
                    "-eq" => Some(a.parse::<i64>().ok()? == b.parse::<i64>().ok()?),
                    "-ne" => Some(a.parse::<i64>().ok()? != b.parse::<i64>().ok()?),
                    _ => None,
                }
            }
            "negated_command" => self
                .condition(node.named_child(0)?, state, depth + 1)
                .map(|v| !v),
            "word" | "string" | "raw_string" | "simple_expansion" | "expansion" => {
                self.word(node, state, depth + 1).map(|v| !v.is_empty())
            }
            "list" => {
                let a = node.named_child(0)?;
                let b = node.named_child(1)?;
                let op = self.source[a.end_byte()..b.start_byte()].trim().to_owned();
                self.logical(a, b, &op, state, depth + 1)
            }
            _ => {
                self.statement(node, state, depth + 1);
                state.status
            }
        }
    }
    fn logical(
        &mut self,
        a: Node<'_>,
        b: Node<'_>,
        op: &str,
        state: &mut State,
        depth: usize,
    ) -> Option<bool> {
        let av = self.condition(a, state, depth + 1);
        if (op == "&&" && av == Some(false)) || (op == "||" && av == Some(true)) {
            return av;
        }
        if av.is_some() {
            let bv = self.condition(b, state, depth + 1);
            return boolean(av, bv, op);
        }
        let original = state.clone();
        let mut branch = state.clone();
        let bv = self.condition(b, &mut branch, depth + 1);
        self.merge(state, original, branch);
        boolean(av, bv, op)
    }
    fn branch(&mut self, node: Node<'_>, state: &mut State, depth: usize) {
        self.branch_tail(node, &[], state, depth);
    }
    fn branch_tail<'tree>(
        &mut self,
        node: Node<'tree>,
        tail: &[Node<'tree>],
        state: &mut State,
        depth: usize,
    ) {
        if !self.budget(depth) {
            return;
        }
        let mut cursor = node.walk();
        let children = node.children(&mut cursor).collect::<Vec<_>>();
        let Some(then) = children.iter().position(|n| n.kind() == "then") else {
            self.issue("unsupported conditional");
            return;
        };
        let mut condition = None;
        for child in &children[..then] {
            if child.is_named() {
                condition = self.condition(*child, state, depth + 1);
                state.status = condition;
            }
        }
        let mut yes = state.clone();
        let mut no = state.clone();
        let mut alternatives = children[then + 1..]
            .iter()
            .copied()
            .filter(|n| matches!(n.kind(), "elif_clause" | "else_clause"))
            .collect::<Vec<_>>();
        alternatives.extend_from_slice(tail);
        for child in &children[then + 1..] {
            if matches!(child.kind(), "elif_clause" | "else_clause") {
                break;
            }
            if child.is_named() && condition != Some(false) && !yes.stopped {
                self.statement(*child, &mut yes, depth + 1);
            }
        }
        if condition != Some(true) {
            if let Some(other) = alternatives.first() {
                if other.kind() == "elif_clause" {
                    self.branch_tail(*other, &alternatives[1..], &mut no, depth + 1)
                } else {
                    let mut c = other.walk();
                    for n in other.named_children(&mut c) {
                        if !no.stopped {
                            self.statement(n, &mut no, depth + 1)
                        }
                    }
                }
            }
        }
        match condition {
            Some(true) => *state = yes,
            Some(false) => *state = no,
            None => self.merge(state, yes, no),
        }
    }
    fn assign(&mut self, node: Node<'_>, state: &mut State, depth: usize) {
        let Some(name) = node.child_by_field_name("name") else {
            self.issue("assignment name");
            return;
        };
        if name.kind() != "variable_name" {
            if let Some(base) = name.child_by_field_name("name") {
                state.vars.insert(self.text(base).into(), None);
            }
            self.issue("array assignment not modeled");
            return;
        }
        let key = self.text(name).to_owned();
        if key == "IFS" {
            self.issue("custom field splitting requires explicit modeling");
        }
        let value_node = node.child_by_field_name("value");
        let mut value = value_node.and_then(|n| self.word(n, state, depth + 1));
        if let Some(n) = value_node {
            let op = self.source[name.end_byte()..n.start_byte()].trim();
            if op == "+=" {
                value = state
                    .vars
                    .get(&key)
                    .cloned()
                    .flatten()
                    .zip(value)
                    .and_then(|(a, b)| (a.len() + b.len() <= MAX_VALUE).then(|| a + &b));
            } else if op != "=" {
                value = None;
            }
        } else {
            value = Some(String::new());
        }
        if state.vars.len() >= MAX_ITEMS && !state.vars.contains_key(&key) {
            self.issue("variable budget exhausted");
            self.steps = 0;
            return;
        }
        if value.as_ref().is_some_and(|v| v.len() > MAX_VALUE) {
            self.issue("variable budget exhausted");
            value = None;
        }
        if let Some(v) = &value {
            self.list_paths(&key, v, state);
            let lower = key.to_ascii_lowercase();
            if lower == "runtime" || lower.ends_with("_runtime") {
                self.runtime_name(v);
            }
        } else if matches!(
            key.as_str(),
            "LD_LIBRARY_PATH" | "LD_PRELOAD" | "SDL_GAMECONTROLLERCONFIG_FILE" | "GPTOKEYB_CONFIG"
        ) {
            self.issue(&format!("unresolved path variable {key}"));
        }
        if value.is_none()
            && (key.eq_ignore_ascii_case("runtime")
                || key.to_ascii_lowercase().ends_with("_runtime"))
        {
            self.issue("unresolved runtime declaration");
        }
        if let Some(v) = &value {
            for part in std::iter::once(v.as_str())
                .chain(v.split(':'))
                .filter(|part| part.starts_with('/') || part.starts_with("./"))
            {
                if v.contains("://") {
                    break;
                }
                if let Some(path) = self.absolute(part, state) {
                    if self.result.declared_paths.len() < MAX_ITEMS {
                        self.result.declared_paths.insert(path);
                    } else {
                        self.issue("declaration count limit");
                    }
                }
            }
        } else if value_node.is_some_and(|n| self.path_template(n)) {
            self.issue("unresolved declared path");
        }
        let unknown_substitution = value.is_none() && self.text(node).contains("$(");
        state.unset.remove(&key);
        state.vars.insert(key, value);
        state.status = if unknown_substitution {
            None
        } else {
            Some(true)
        };
    }
    fn source_file(&mut self, path: &str, state: &mut State, depth: usize) {
        let Some(path) = self.absolute(path, state).map(PathBuf::from) else {
            self.issue("unresolved source path");
            return;
        };
        if self.changed(&path) {
            self.poison(state, "source was modified by analyzed script");
            return;
        }
        if self.stack.contains(&path)
            || self.stack.len() >= 16
            || self.result.sources.len() >= MAX_ITEMS
        {
            self.issue("source cycle/depth limit");
            return;
        }
        match self.environment.read(&path) {
            Ok(source) => {
                self.result
                    .sources
                    .insert(path.to_string_lossy().into_owned());
                self.stack.push(path.clone());
                let stopped = state.stopped;
                state.stopped = false;
                self.run(&source, &path, state, depth + 1);
                state.stopped = stopped || state.exited;
                self.stack.pop();
            }
            Err(reason) => {
                self.issue(&reason);
                for value in state.vars.values_mut() {
                    *value = None;
                }
                state.cwd = None;
            }
        }
    }
    fn command(&mut self, node: Node<'_>, state: &mut State, depth: usize) {
        if node
            .child_by_field_name("name")
            .is_some_and(|name| matches!(self.text(name), "sleep" | "kill"))
            && self.passive_wait(node, state, depth + 1)
        {
            self.note("path-independent process wait/probe not executed");
            state.status = None;
            return;
        }
        let mut local = state.clone();
        let mut cursor = node.walk();
        let mut words = Vec::new();
        for n in node.named_children(&mut cursor) {
            if n.kind() == "variable_assignment" {
                self.assign(n, &mut local, depth + 1)
            } else {
                words.push(n);
            }
        }
        let mut args = words
            .iter()
            .map(|n| self.word(*n, &local, depth + 1))
            .collect::<Vec<_>>();
        for (word, value) in words.iter().zip(&args) {
            if !matches!(word.kind(), "string" | "raw_string")
                && value.as_ref().is_some_and(|v| {
                    v.chars()
                        .any(|c| c.is_whitespace() || matches!(c, '*' | '?' | '['))
                })
                && word.kind() != "command_name"
            {
                self.issue("unquoted field splitting or globbing");
            }
        }
        // An unquoted command expansion participates in field splitting too:
        // TASKSET='' elides the prefix, CMD='cd /game' invokes the builtin.
        if words
            .first()
            .and_then(|n| n.named_child(0))
            .is_some_and(|n| {
                matches!(
                    n.kind(),
                    "simple_expansion" | "expansion" | "command_substitution"
                )
            })
        {
            if let Some(Some(value)) = args.first() {
                let tokens = value
                    .split_ascii_whitespace()
                    .map(|v| Some(v.to_owned()))
                    .collect::<Vec<_>>();
                args.splice(..1, tokens);
            }
        }
        let name = args.first().cloned().flatten();
        let raw = self.text(node).to_owned();
        let previous_status = state.status;
        state.status = self.environment.command_status(&raw);
        if name.is_none() {
            self.poison(state, "unresolved command name");
            return;
        }
        if let Some((index, kind)) = args
            .iter()
            .enumerate()
            .filter_map(|(i, a)| a.as_ref().map(|a| (i, a)))
            .find_map(|(i, a)| {
                let name = Path::new(a).file_name()?.to_str()?;
                matches!(
                    name,
                    "cp" | "mv" | "rm" | "mkdir" | "rmdir" | "touch" | "install" | "ln"
                )
                .then_some((i, name))
            })
        {
            let operands = args
                .iter()
                .skip(index + 1)
                .flatten()
                .filter(|p| !p.starts_with('-'))
                .collect::<Vec<_>>();
            let targets = if matches!(kind, "cp" | "install" | "ln") {
                operands.last().copied().into_iter().collect::<Vec<_>>()
            } else {
                operands
            };
            for path in targets {
                if let Some(path) = self.record(path, &local, "output") {
                    if matches!(kind, "cp" | "mv" | "rm" | "rmdir" | "install" | "ln")
                        && self.changed_trees.len() < MAX_ITEMS
                    {
                        self.changed_trees.insert(path);
                    }
                }
            }
        }
        match name.as_deref() {
            Some("source" | ".") => {
                if let Some(Some(path)) = args.get(1) {
                    if args.len() > 2 {
                        self.issue("source positional arguments unsupported");
                    }
                    self.source_file(path, state, depth + 1);
                } else {
                    self.issue("unresolved source path");
                    for value in state.vars.values_mut() {
                        *value = None;
                    }
                }
                return;
            }
            Some("cd" | "pushd") => {
                let path = if args.get(1).and_then(|v| v.as_deref()) == Some("--") {
                    args.get(2)
                } else {
                    args.get(1)
                };
                state.cwd = path
                    .cloned()
                    .flatten()
                    .and_then(|v| self.record(&v, &local, "cwd"));
                if state.cwd.is_none() {
                    self.issue("unresolved working directory");
                }
                state.status = Some(true);
                return;
            }
            Some("return" | "exit") => {
                state.stopped = true;
                state.exited |= name.as_deref() == Some("exit");
                if let Some(code) = args.get(1) {
                    state.status = code
                        .as_deref()
                        .and_then(|v| v.parse::<i32>().ok())
                        .map(|v| v == 0);
                } else {
                    state.status = previous_status;
                }
                return;
            }
            Some("true" | ":") => {
                state.status = Some(true);
                return;
            }
            Some("false") => {
                state.status = Some(false);
                return;
            }
            Some("command") if args.get(1).and_then(|v| v.as_deref()) == Some("-v") => {
                return;
            }
            Some("unset") => {
                self.unset_names(&args[1..], state);
                return;
            }
            Some("eval") => {
                if let Some(parts) = args.iter().skip(1).cloned().collect::<Option<Vec<_>>>() {
                    let code = parts.join(" ");
                    let file = self.file.clone();
                    self.run(&code, &file, state, depth + 1);
                } else {
                    self.poison(state, "unresolved eval code");
                }
                return;
            }
            Some(
                "alias" | "unalias" | "read" | "mapfile" | "readarray" | "getopts" | "popd" | "set"
                | "shopt" | "enable" | "builtin" | "let" | "shift" | "break" | "continue"
                | "command",
            ) => {
                self.issue("dynamic Shell state unsupported");
                for value in state.vars.values_mut() {
                    *value = None;
                }
                return;
            }
            Some("echo" | "printf") => {
                if args.get(1).and_then(|v| v.as_deref()) == Some("-v") {
                    self.issue("printf assignment unsupported");
                }
                return;
            }
            Some("trap") => {
                if args
                    .iter()
                    .skip(2)
                    .any(|v| !matches!(v.as_deref(), Some("EXIT" | "0")))
                {
                    self.issue("asynchronous trap state unsupported");
                }
                if let Some(Some(handler)) = args.get(1) {
                    if self.traps.len() < 32 {
                        self.traps.push(handler.clone());
                    } else {
                        self.issue("trap count limit");
                    }
                } else {
                    self.issue("unresolved trap handler");
                }
                return;
            }
            Some("tee") => {
                for arg in args.iter().skip(1) {
                    if let Some(path) = arg {
                        if !path.starts_with('-') {
                            self.record(path, &local, "output");
                        }
                    } else {
                        self.issue("unresolved output path");
                    }
                }
                return;
            }
            _ => (),
        }
        if let Some((body, file)) = name
            .as_ref()
            .and_then(|name| state.functions.get(name))
            .cloned()
        {
            if depth >= MAX_DEPTH {
                self.issue("function recursion limit");
                return;
            }
            let saved = state
                .vars
                .iter()
                .filter(|(k, _)| k.bytes().all(|c| c.is_ascii_digit()))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect::<BTreeMap<_, _>>();
            let old_unset = state.unset.clone();
            for i in 1..=9 {
                state.vars.insert(i.to_string(), Some(String::new()));
            }
            for (i, v) in args.iter().skip(1).enumerate() {
                state.vars.insert((i + 1).to_string(), v.clone());
            }
            self.locals.push(BTreeMap::new());
            let stopped = state.stopped;
            state.stopped = false;
            self.run(&body, &file, state, depth + 1);
            state.stopped = stopped || state.exited;
            for (key, old) in self.locals.pop().unwrap() {
                if old_unset.contains(&key) {
                    state.unset.insert(key.clone());
                } else {
                    state.unset.remove(&key);
                }
                if let Some(v) = old {
                    state.vars.insert(key, v);
                } else {
                    state.vars.remove(&key);
                }
            }
            state
                .vars
                .retain(|k, _| !k.bytes().all(|c| c.is_ascii_digit()));
            state.vars.extend(saved);
            return;
        }
        // Shell expands unquoted command variables into words, e.g. LOVE_RUN="env
        // LD_LIBRARY_PATH=... /path/love". Reparse DATA as words, never as commands.
        if let Some(name) = &name {
            if name.contains(char::is_whitespace) {
                for token in name.split_ascii_whitespace() {
                    if let Some((key, v)) = token.split_once('=') {
                        self.list_paths(key, v, &local);
                    } else {
                        self.record(token, &local, "argument");
                    }
                }
            } else {
                self.record(name, &local, "argument");
            }
        }
        for (i, arg) in args.iter().enumerate().skip(1) {
            let previous = args.get(i - 1).and_then(|v| v.as_deref());
            let input = previous == Some("-c")
                && (raw.contains("GPTOKEYB")
                    || name.as_ref().is_some_and(|n| n.contains("gptokeyb")));
            if let Some(arg) = arg {
                let path = if let Some((key, v)) = arg.split_once('=') {
                    if matches!(key, "LD_LIBRARY_PATH" | "LD_PRELOAD") {
                        self.list_paths(key, v, &local);
                        continue;
                    }
                    if key.starts_with("--") { v } else { arg }
                } else {
                    arg
                };
                self.record(path, &local, if input { "input" } else { "argument" });
            } else {
                self.issue(&format!(
                    "unresolved command argument at line {} ({})",
                    node.start_position().row + 1,
                    name.as_deref().unwrap_or("?")
                ));
            }
        }
    }
    fn redirect(&mut self, node: Node<'_>, state: &mut State, depth: usize) {
        let duplicate = self.text(node).contains(">&") || self.text(node).contains("<&");
        let input = self
            .text(node)
            .trim_start()
            .trim_start_matches(|c: char| c.is_ascii_digit())
            .starts_with('<');
        let mut c = node.walk();
        for target in node.children_by_field_name("destination", &mut c) {
            if target.kind() == "process_substitution" {
                let mut child = state.clone();
                let mut pc = target.walk();
                for command in target.named_children(&mut pc) {
                    self.statement(command, &mut child, depth + 1);
                }
            } else if let Some(v) = self.word(target, state, depth + 1) {
                if duplicate && (v == "-" || !v.is_empty() && v.bytes().all(|c| c.is_ascii_digit()))
                {
                    continue;
                }
                self.record(&v, state, if input { "read" } else { "output" });
            } else {
                self.issue("unresolved redirection path");
            }
        }
    }
    // Prove a small path-independent subset structurally. Never evaluate words
    // here: substitutions and parameter assignments can hide state changes.
    fn passive_wait(&mut self, node: Node<'_>, state: &State, depth: usize) -> bool {
        if !self.budget(depth) {
            return false;
        }
        match node.kind() {
            "comment" => true,
            "while_statement"
            | "do_group"
            | "compound_statement"
            | "list"
            | "negated_command"
            | "redirected_statement" => {
                let mut cursor = node.walk();
                node.named_children(&mut cursor)
                    .all(|child| self.passive_wait(child, state, depth + 1))
            }
            "file_redirect" => matches!(
                self.text(node)
                    .split_whitespace()
                    .collect::<String>()
                    .as_str(),
                ">/dev/null" | "1>/dev/null" | "2>/dev/null"
            ),
            "command" => {
                let Some(name) = node.child_by_field_name("name") else {
                    return false;
                };
                let command = self.text(name);
                if !matches!(command, "sleep" | "kill" | "true" | "false" | ":")
                    || state.functions.contains_key(command)
                {
                    return false;
                }
                let mut cursor = node.walk();
                let args = node
                    .named_children(&mut cursor)
                    .filter(|child| child.id() != name.id())
                    .collect::<Vec<_>>();
                // Only process-existence probes, never signal delivery.
                if command == "kill"
                    && (args.len() != 2
                        || !args.first().is_some_and(|arg| {
                            matches!(arg.kind(), "word" | "number") && self.text(*arg) == "-0"
                        })
                        || !matches!(args[1].kind(), "number" | "string" | "raw_string"))
                {
                    return false;
                }
                args.into_iter()
                    .all(|arg| self.passive_word(arg, depth + 1))
            }
            _ => false,
        }
    }

    fn passive_word(&mut self, node: Node<'_>, depth: usize) -> bool {
        if !self.budget(depth) {
            return false;
        }
        match node.kind() {
            "word" | "number" | "raw_string" | "string_content" => true,
            "simple_expansion" => !matches!(self.text(node), "$@" | "$*"),
            "expansion" => self
                .text(node)
                .strip_prefix("${")
                .and_then(|value| value.strip_suffix('}'))
                .is_some_and(|name| {
                    !name.is_empty() && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                }),
            "string" | "concatenation" => {
                let mut cursor = node.walk();
                node.named_children(&mut cursor)
                    .all(|child| self.passive_word(child, depth + 1))
            }
            _ => false,
        }
    }

    fn statement(&mut self, node: Node<'_>, state: &mut State, depth: usize) {
        if state.stopped || !self.budget(depth) {
            return;
        }
        match node.kind() {
            "comment" => (),
            "program" | "compound_statement" | "else_clause" | "do_group" => {
                let mut c = node.walk();
                for n in node.named_children(&mut c) {
                    self.statement(n, state, depth + 1);
                }
            }
            "variable_assignment" => self.assign(node, state, depth + 1),
            "command" => self.command(node, state, depth + 1),
            "file_redirect" => self.redirect(node, state, depth + 1),
            "if_statement" | "elif_clause" => self.branch(node, state, depth + 1),
            "test_command" => {
                state.status = self.condition(node, state, depth + 1);
            }
            "negated_command" => {
                state.status = self.condition(node, state, depth + 1);
            }
            "function_definition" => {
                if let (Some(name), Some(body)) = (
                    node.child_by_field_name("name"),
                    node.child_by_field_name("body"),
                ) {
                    if state.functions.len() >= MAX_ITEMS {
                        self.issue("function count limit");
                        return;
                    }
                    state.functions.insert(
                        self.text(name).into(),
                        (self.text(body).into(), self.file.clone()),
                    );
                }
            }
            "declaration_command" => {
                let declaration = self.text(node);
                if declaration.starts_with("readonly ")
                    || declaration.starts_with("declare ")
                    || declaration.starts_with("typeset ")
                    || declaration
                        .split_ascii_whitespace()
                        .nth(1)
                        .is_some_and(|v| v.starts_with('-'))
                {
                    self.issue("declaration attributes are not modeled");
                }
                let is_local = self.text(node).starts_with("local ");
                let mut c = node.walk();
                for n in node.named_children(&mut c) {
                    if n.kind() == "variable_assignment" {
                        if is_local {
                            if let Some(name) = n.child_by_field_name("name") {
                                let key = self.text(name).to_owned();
                                if let Some(scope) = self.locals.last_mut() {
                                    scope
                                        .entry(key.clone())
                                        .or_insert_with(|| state.vars.get(&key).cloned());
                                }
                            }
                        }
                        self.assign(n, state, depth + 1);
                    }
                }
            }
            "list" => {
                let a = node.named_child(0);
                let b = node.named_child(1);
                if let (Some(a), Some(b)) = (a, b) {
                    let op = self.source[a.end_byte()..b.start_byte()].trim().to_owned();
                    self.statement(a, state, depth + 1);
                    let run = match op.as_str() {
                        "&&" => state.status,
                        "||" => state.status.map(|v| !v),
                        _ => Some(true),
                    };
                    match run {
                        Some(true) => self.statement(b, state, depth + 1),
                        Some(false) => (),
                        None => {
                            let original = state.clone();
                            let mut branch = state.clone();
                            self.statement(b, &mut branch, depth + 1);
                            self.merge(state, original, branch);
                        }
                    }
                }
            }
            "redirected_statement" => {
                let mut c = node.walk();
                for n in node.named_children(&mut c) {
                    if n.kind() == "file_redirect" {
                        self.redirect(n, state, depth + 1);
                    } else if matches!(n.kind(), "heredoc_redirect" | "herestring_redirect") {
                        self.note("redirect data not executed");
                    } else {
                        self.statement(n, state, depth + 1);
                    }
                }
            }
            "pipeline" | "subshell" => {
                let mut c = node.walk();
                for n in node.named_children(&mut c) {
                    let mut child = state.clone();
                    self.statement(n, &mut child, depth + 1);
                }
                state.status = None;
            }
            "for_statement" => {
                let mut c = node.walk();
                let nodes = node
                    .children_by_field_name("value", &mut c)
                    .collect::<Vec<_>>();
                let mut values = Vec::new();
                if nodes.is_empty() {
                    self.poison(state, "implicit positional loop unsupported");
                    return;
                }
                for n in nodes {
                    let Some(v) = self.word(n, state, depth + 1) else {
                        self.poison(state, "unresolved loop values");
                        return;
                    };
                    if matches!(n.kind(), "string" | "raw_string") {
                        values.push(v);
                    } else if v.chars().any(|c| matches!(c, '*' | '?' | '[')) {
                        self.poison(state, "loop glob requires filesystem snapshot");
                        return;
                    } else {
                        values.extend(v.split_ascii_whitespace().map(str::to_owned));
                    }
                }
                if values.len() > 64 {
                    self.poison(state, "loop iteration limit");
                    return;
                }
                if let (Some(var), Some(body)) = (
                    node.child_by_field_name("variable"),
                    node.child_by_field_name("body"),
                ) {
                    let key = self.text(var).to_owned();
                    for value in values {
                        state.vars.insert(key.clone(), Some(value));
                        self.statement(body, state, depth + 1);
                        if state.stopped {
                            break;
                        }
                    }
                }
            }
            "case_statement" => {
                let value = node
                    .child_by_field_name("value")
                    .and_then(|n| self.word(n, state, depth + 1));
                let original = state.clone();
                let mut states = Vec::new();
                let mut possible = true;
                let mut c = node.walk();
                for item in node
                    .named_children(&mut c)
                    .filter(|n| n.kind() == "case_item")
                {
                    if !possible {
                        break;
                    }
                    let mut pc = item.walk();
                    let patterns = item
                        .children_by_field_name("value", &mut pc)
                        .collect::<Vec<_>>();
                    let mut matched = Some(false);
                    for pattern in &patterns {
                        let wildcard =
                            pattern.kind() == "word" && self.text(*pattern).trim() == "*";
                        let m = if wildcard {
                            Some(true)
                        } else {
                            value
                                .as_ref()
                                .and_then(|v| self.case_match(*pattern, v, state, depth + 1))
                        };
                        matched = boolean(matched, m, "||");
                    }
                    if matched != Some(false) {
                        let mut branch = original.clone();
                        let mut bc = item.walk();
                        for body in item
                            .named_children(&mut bc)
                            .filter(|n| !patterns.iter().any(|p| p.id() == n.id()))
                        {
                            self.statement(body, &mut branch, depth + 1);
                        }
                        if item.child_by_field_name("fallthrough").is_some() {
                            self.poison(&mut branch, "case fallthrough unsupported");
                        }
                        states.push(branch);
                    }
                    possible = matched != Some(true);
                }
                if possible {
                    states.push(original);
                }
                if let Some(first) = states.pop() {
                    *state = first;
                    for branch in states {
                        self.merge(state, state.clone(), branch);
                    }
                }
            }
            "while_statement" => {
                if self.passive_wait(node, state, depth + 1) {
                    self.note("path-independent wait loop not executed");
                    // Neither its termination nor exit status is known. Keep
                    // subsequent status-dependent branches conservative.
                    state.status = None;
                } else {
                    self.poison(state, "unbounded loop requires runtime input");
                }
            }
            "unset_command" => {
                let mut c = node.walk();
                let names = node
                    .named_children(&mut c)
                    .map(|n| self.word(n, state, depth + 1))
                    .collect::<Vec<_>>();
                self.unset_names(&names, state);
            }
            "word" | "string" | "raw_string" | "variable_name" | "number" => (),
            _ => {
                self.issue(&format!("unsupported statement {}", node.kind()));
            }
        }
    }
}
fn unescape(text: &str, quoted: bool) -> String {
    let mut result = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            result.push(c);
            continue;
        }
        if let Some(next) = chars.next() {
            if next == '\n' {
                continue;
            }
            if quoted && !matches!(next, '$' | '`' | '"' | '\\') {
                result.push('\\');
            }
            result.push(next);
        } else {
            result.push('\\');
        }
    }
    result
}
fn boolean(a: Option<bool>, b: Option<bool>, op: &str) -> Option<bool> {
    match op {
        "&&" => {
            if a == Some(false) || b == Some(false) {
                Some(false)
            } else {
                a.zip(b).map(|(a, b)| a && b)
            }
        }
        "||" => {
            if a == Some(true) || b == Some(true) {
                Some(true)
            } else {
                a.zip(b).map(|(a, b)| a || b)
            }
        }
        _ => None,
    }
}
