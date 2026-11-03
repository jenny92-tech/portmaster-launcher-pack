// INPUT:  Bash AST、显式变量、source 只读输入或离线设备快照
// OUTPUT: 路径、库搜索路径、输入输出及诊断；按托管 libs 位置关联可下载镜像
// POS:    Shell 路径分析公开边界；不执行任何原脚本

use crate::shell_sources::{SnapshotEnvironment, SourceEnvironment};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;

#[derive(Debug, Default, Clone)]
pub struct PathAnalysis {
    pub paths: BTreeSet<String>,
    /// Protective declaration hints, never sufficient to authorize deletion.
    pub declared_paths: BTreeSet<String>,
    pub working_directories: BTreeSet<String>,
    pub library_paths: BTreeSet<String>,
    pub preload_libraries: BTreeSet<String>,
    pub input_configs: BTreeSet<String>,
    pub output_paths: BTreeSet<String>,
    pub sources: BTreeSet<String>,
    pub runtime_names: Vec<String>,
    /// Conservative blockers, including unsupported Shell state/control semantics.
    pub diagnostics: BTreeSet<String>,
    /// Non-path limitations, such as log output, are reported separately.
    pub notes: BTreeSet<String>,
}
impl PathAnalysis {
    pub fn uncertain(&self) -> bool {
        !self.diagnostics.is_empty()
    }

    /// Downloadable libs image candidates, independent of Shell variable names. The
    /// repair boundary must still match each name and architecture to metadata.
    pub fn runtime_dependencies(
        &self,
        libs: Option<&Path>,
        environment: &dyn SourceEnvironment,
    ) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        let libs = libs
            .and_then(|path| environment.runtime_location(path))
            .filter(|root| root.parent().is_some());
        for value in self
            .paths
            .iter()
            .chain(&self.declared_paths)
            .chain(&self.sources)
        {
            let Some(path) = environment.runtime_location(Path::new(value)) else {
                continue;
            };
            if let Some(relative) = libs.as_ref().and_then(|root| path.strip_prefix(root).ok()) {
                if relative.components().count() == 1 {
                    if let Some(name) = relative.to_str().and_then(|v| v.strip_suffix(".squashfs"))
                    {
                        if valid_runtime_name(name) {
                            names.insert(name.to_owned());
                        }
                    }
                }
            }
        }
        names
    }
}

fn valid_runtime_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && !name.contains("..")
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'+' | b'-'))
}

pub fn analyze(source: &str, variables: &BTreeMap<String, String>, script: &Path) -> PathAnalysis {
    analyze_with_environment(source, variables, script, &SnapshotEnvironment::default())
}

pub fn analyze_with_environment(
    source: &str,
    variables: &BTreeMap<String, String>,
    script: &Path,
    environment: &dyn SourceEnvironment,
) -> PathAnalysis {
    crate::shell_eval::analyze(source, variables, script, environment)
}

#[cfg(test)]
#[path = "shell_paths_integration_tests.rs"]
mod integration_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn runtime_aliases_use_only_the_explicit_snapshot() {
        let env = SnapshotEnvironment {
            complete: true,
            links: BTreeMap::from([
                (
                    PathBuf::from("/virtual/card"),
                    PathBuf::from("/virtual/real"),
                ),
                (
                    PathBuf::from("/virtual/real/libs/escape.squashfs"),
                    PathBuf::from("/outside/image.squashfs"),
                ),
                (PathBuf::from("/cycle"), PathBuf::from("/cycle")),
            ]),
            ..Default::default()
        };
        let result = scan(
            "A=/virtual/card/libs/godot.squashfs\nB=/virtual/card/libs/escape.squashfs\nC=/cycle/loop.squashfs\n",
        );
        assert_eq!(
            result.runtime_dependencies(Some(Path::new("/virtual/real/libs")), &env),
            BTreeSet::from(["godot".into()])
        );
        assert!(
            result
                .runtime_dependencies(
                    Some(Path::new("/virtual/real/libs")),
                    &SnapshotEnvironment::default()
                )
                .is_empty()
        );
    }
    #[test]
    fn runtime_locations_are_scoped_and_ignore_output_only_references() {
        let root = tempfile::tempdir().unwrap();
        let pm = root.path().join("PortMaster");
        let libs = pm.join("libs");
        let result = analyze(
            &format!(
                "WHATEVER='{}/engine.squashfs'\njava -cp '{}/runtimes/jdk/lib/a.jar:{}/runtimes/jdk/lib/b.jar' Main\nprintf x > '{}/output.squashfs'\nX='{}/libs-other/no.squashfs'\nY='{}/../foreign.squashfs'\n",
                libs.display(),
                pm.display(),
                pm.display(),
                libs.display(),
                pm.display(),
                libs.display(),
            ),
            &BTreeMap::new(),
            Path::new("/ports/游戏.sh"),
        );
        assert_eq!(
            result
                .runtime_dependencies(Some(&libs), &crate::shell_sources::FileEnvironment::new([])),
            BTreeSet::from(["engine".into()])
        );
        assert!(
            result
                .runtime_dependencies(None, &SnapshotEnvironment::default())
                .is_empty()
        );
    }

    #[test]
    fn path_list_detection_preserves_literal_colon_filename_references() {
        let result = scan("/roms/ports/Game:Edition/game\n");
        assert!(result.paths.contains("/roms/ports/Game:Edition/game"));
    }

    #[cfg(unix)]
    #[test]
    fn runtime_locations_follow_root_aliases_but_not_escaping_children() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let pm = root.path().join("PortMaster");
        std::fs::create_dir_all(pm.join("libs")).unwrap();
        std::fs::create_dir_all(pm.join("runtimes")).unwrap();
        let alias = root.path().join("card-link");
        symlink(&pm, &alias).unwrap();
        let foreign = root.path().join("foreign");
        std::fs::create_dir(&foreign).unwrap();
        symlink(&foreign, pm.join("runtimes/escaped")).unwrap();
        symlink(
            root.path().join("absent"),
            pm.join("libs/dangling.squashfs"),
        )
        .unwrap();
        let result = analyze(
            &format!(
                "A='{}/libs/missing.squashfs'\nB='{}/runtimes/escaped/lib/x.so'\nC='{}/libs/dangling.squashfs'\n",
                alias.display(),
                alias.display(),
                alias.display(),
            ),
            &BTreeMap::new(),
            Path::new("/ports/game.sh"),
        );
        assert_eq!(
            result.runtime_dependencies(
                Some(&pm.join("libs")),
                &crate::shell_sources::FileEnvironment::new([])
            ),
            BTreeSet::from(["missing".into()])
        );
    }
    fn scan(source: &str) -> PathAnalysis {
        analyze(
            source,
            &BTreeMap::from([("directory".into(), "/roms".into())]),
            Path::new("/roms/ports/中文.sh"),
        )
    }
    #[test]
    fn follows_arbitrary_names_and_input_configuration() {
        let result = scan(
            "ROOT=/$directory/ports\nOTHER=\"$ROOT/goldminer\"\ncd \"$OTHER\"\ngptokeyb game -c './keyboard.gptk'\n./game",
        );
        assert!(!result.uncertain(), "{:?}", result.diagnostics);
        assert!(result.paths.contains("/roms/ports/goldminer/keyboard.gptk"));
        assert!(result.working_directories.contains("/roms/ports/goldminer"));
    }
    #[test]
    fn assignments_are_ordered_and_single_quotes_are_literal() {
        let result =
            scan("A=/roms/ports/old\nA=/roms/ports/new\ncd \"$A\"\nprintf '%s' '$A/literal'");
        assert!(result.working_directories.contains("/roms/ports/new"));
        assert!(!result.working_directories.contains("/roms/ports/old"));
        // Printed strings are not file references.
        assert!(!result.paths.contains("/roms/ports/new/$A/literal"));
    }
    #[test]
    fn models_dirname_without_executing() {
        let result = scan("CUSTOM=\"$(dirname \"$0\")/game\"\ncd \"$CUSTOM\"");
        assert!(!result.uncertain(), "{:?}", result.diagnostics);
        assert!(result.working_directories.contains("/roms/ports/game"));
    }
    #[test]
    fn unknown_never_becomes_empty_or_successful_execution() {
        for source in [
            "cd \"$UNKNOWN/game\"",
            "X=$(touch /tmp/never-run)\ncd \"$X\"",
            "source /some/control.txt\ncd \"$directory/ports/game\"",
            "if test x; then X=/a; else X=/b; fi\ncd \"$X\"",
            "cd \"unterminated",
        ] {
            assert!(scan(source).uncertain(), "{source}");
        }
    }
    #[test]
    fn tracks_shared_directories() {
        let result = scan(
            "A=/roms/ports/counter-strike\nB=/roms/ports/Half-Life\ncd \"$A\"\nbind_directories \"$B/valve\" \"$A/valve\"",
        );
        assert!(result.paths.contains("/roms/ports/Half-Life/valve"));
        assert!(result.paths.contains("/roms/ports/counter-strike/valve"));
    }

    #[test]
    fn defaults_and_empty_assignments() {
        let result = scan("X=''\nY=${X:-/roms/ports/fallback}\ncd \"$Y\"");
        assert!(!result.uncertain(), "{:?}", result.diagnostics);
        assert!(result.working_directories.contains("/roms/ports/fallback"));
    }

    #[test]
    fn bounds_expansion_and_rejects_unmodeled_assignment_semantics() {
        let mut source = String::from("X=abcdef\n");
        for _ in 0..30 {
            source.push_str("X=\"$X$X\"\n");
        }
        assert!(scan(&source).uncertain());
        let appended = scan("X=/ports/a\nX+=/b\ncd \"$X\"");
        assert!(!appended.uncertain());
        assert!(appended.working_directories.contains("/ports/a/b"));
        assert!(scan("X='/ports/a b'\ncd $X").uncertain());
    }

    #[test]
    fn hostile_scripts_cannot_touch_files() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("must-not-exist");
        let source = format!(
            "X=$(touch '{}')\necho overwrite > '{}'\nsource '{}'",
            target.display(),
            target.display(),
            target.display()
        );
        assert!(scan(&source).uncertain());
        assert!(!target.exists());
    }

    #[test]
    #[ignore = "requires explicitly supplied, read-only PortMaster corpus"]
    fn survey_corpus() {
        let root = std::env::var_os("PM_SHELL_CORPUS").expect("set PM_SHELL_CORPUS");
        let mut files = Vec::new();
        fn visit(dir: &Path, files: &mut Vec<PathBuf>) {
            for entry in std::fs::read_dir(dir).unwrap() {
                let entry = entry.unwrap();
                let kind = entry.file_type().unwrap();
                if kind.is_dir() {
                    visit(&entry.path(), files);
                } else if kind.is_file()
                    && entry
                        .path()
                        .extension()
                        .is_some_and(|x| x.eq_ignore_ascii_case("sh"))
                {
                    files.push(entry.path());
                }
            }
        }
        visit(Path::new(&root), &mut files);
        let mut with_paths = 0;
        let mut uncertain = 0;
        let mut errors = 0;
        for file in &files {
            let source = std::fs::read(file).unwrap();
            let result = scan(&String::from_utf8_lossy(&source));
            with_paths += usize::from(!result.paths.is_empty());
            uncertain += usize::from(result.uncertain());
            errors += usize::from(
                result
                    .diagnostics
                    .contains("invalid or unsupported Shell syntax"),
            );
        }
        println!(
            "files={} with_path_candidates={with_paths} uncertain={uncertain} syntax_errors={errors}",
            files.len()
        );
        assert!(!files.is_empty());
    }
}
