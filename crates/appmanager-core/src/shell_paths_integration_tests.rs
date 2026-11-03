// INPUT:  人工边界样例及显式指定的官方离线语料
// OUTPUT: source/分支/libs/输入映射正确性与安全回归
// POS:    Shell 路径后端的行为契约，不运行被测脚本

use super::*;

#[test]
fn passive_wait_preserves_paths_and_runtime_evidence_without_executing() {
    let env = SnapshotEnvironment {
        complete: true,
        ..Default::default()
    };
    let result = analyze_fixture(
        "GAME=/roms/ports/game\nIMAGE=/pm/libs/engine.squashfs\nsleep \"$DELAY\"\nwhile kill -0 \"$GAME_PID\" 2>/dev/null; do sleep 1; done\ncd \"$GAME\"\nLD_LIBRARY_PATH=\"$IMAGE\"\n",
        &env,
    );
    assert!(!result.uncertain(), "{result:#?}");
    assert!(
        result
            .notes
            .iter()
            .any(|note| note.contains("path-independent wait"))
    );
    assert!(result.working_directories.contains("/roms/ports/game"));
    assert_eq!(
        result.runtime_dependencies(Some(Path::new("/pm/libs")), &env),
        BTreeSet::from(["engine".into()])
    );
}

#[test]
fn loops_with_possible_path_or_shell_effects_remain_blockers() {
    for body in [
        "GAME=/other",
        "cd /other",
        "source /helper.txt",
        "LD_LIBRARY_PATH=/other/libs",
        "runtime=other",
        "mount /image /target",
        "sleep $(source /helper.txt)",
        "sleep ${GAME:=/other}",
        "sleep 1 > /helper.txt",
        "sleep 1 2>\"$LOG\"",
        "eval \"$CODE\"",
        "custom_wait",
        "wait -p GAME",
        "kill -9 \"$GAME_PID\"",
    ] {
        let text = format!("GAME=/roms/ports/game\nwhile true; do {body}; done\ncd \"$GAME\"\n");
        let result = analyze_fixture(&text, &SnapshotEnvironment::default());
        assert!(result.uncertain(), "{body}: {result:#?}");
        assert!(
            !result.working_directories.contains("/roms/ports/game"),
            "{body}"
        );
    }
    for prefix in ["sleep() { cd /other; }", "kill() { source /helper.txt; }"] {
        let text = format!("{prefix}\nwhile kill -0 \"$PID\"; do sleep 1; done\n");
        assert!(analyze_fixture(&text, &SnapshotEnvironment::default()).uncertain());
    }
}

#[test]
fn passive_wait_does_not_preserve_a_stale_success_status() {
    let result = analyze_fixture(
        "true\nwhile kill -0 \"$PID\"; do sleep 1; done && cd /first || cd /second\n",
        &SnapshotEnvironment::default(),
    );
    assert!(result.working_directories.contains("/first"), "{result:#?}");
    assert!(
        result.working_directories.contains("/second"),
        "{result:#?}"
    );
}

#[test]
fn official_dialog_eval_idiom_is_interpreted_without_a_shell() {
    let script = r#"SDL_VIDEODRIVER=''
SAVE_CLEAN_ENV=''
for VAR in SDL_VIDEODRIVER; do
 eval "VAL=\${$VAR+set}"
 if [ "$VAL" = "set" ]; then
   eval "SAVE_CLEAN_ENV=\"$SAVE_CLEAN_ENV $VAR=\${$VAR}\""
 fi
done
cd /roms/ports/game
"#;
    let r = analyze_fixture(script, &SnapshotEnvironment::default());
    assert!(!r.uncertain(), "{r:#?}");
}

#[test]
fn cases_unset_defaults_and_command_prefixes_preserve_shell_meaning() {
    let source = r#"CFW=MiniLoong
case "$CFW" in
 TrimUI) GAME=/wrong ;;
 MiniLoong|Other) GAME=/roms/ports/game ;;
 *) GAME=/unknown ;;
esac
unset EMPTY
A=${EMPTY-/roms/ports/fallback}
B=${EMPTY+bad}
CMD='cd /roms/ports/game'
$CMD
PREFIX=''
$PREFIX ./game -c "$A"
"#;
    let r = analyze_fixture(source, &SnapshotEnvironment::default());
    assert!(!r.uncertain(), "{r:#?}");
    assert!(r.working_directories.contains("/roms/ports/game"));
    assert!(!r.declared_paths.contains("/wrong"));
    assert!(r.paths.contains("/roms/ports/fallback"));
}

#[test]
fn traps_sources_and_short_circuit_control_flow_cannot_hide_references() {
    let env = SnapshotEnvironment {
        files: BTreeMap::from([(PathBuf::from("/exit.txt"), "exit 0\n".into())]),
        ..Default::default()
    };
    let r = analyze_fixture(
        "trap 'cd /roms/ports/trap-data' EXIT\nif true || source /missing.txt; then cd /roms/ports/game; fi\nsource /exit.txt\ncd /never\n",
        &env,
    );
    assert!(!r.uncertain(), "{r:#?}");
    assert!(r.working_directories.contains("/roms/ports/trap-data"));
    assert!(!r.working_directories.contains("/never"));
    let modified = SnapshotEnvironment {
        files: BTreeMap::from([(PathBuf::from("/helper.txt"), "GAME=/old".into())]),
        ..Default::default()
    };
    assert!(
        analyze_fixture(
            "echo 'GAME=/new' > /helper.txt\nsource /helper.txt\ncd \"$GAME\"",
            &modified
        )
        .uncertain()
    );
    assert!(analyze_fixture("$UNKNOWN\ncd /game", &env).uncertain());
}

#[test]
fn quote_whitespace_runtime_and_output_classification() {
    let r = analyze_fixture(
        "A=/roms/ports\nB='Space Game'\nGAME=\"$A/$B\"\ncd \"$GAME\"\nruntime=godot_4\nOTHER=\"/pm/libs/mono.squashfs\"\nexec > >(tee \"$GAME/log.txt\") 2>&1\n",
        &SnapshotEnvironment::default(),
    );
    assert!(!r.uncertain(), "{r:#?}");
    assert_eq!(r.runtime_names, ["godot_4"]);
    assert_eq!(
        r.runtime_dependencies(
            Some(Path::new("/pm/libs")),
            &SnapshotEnvironment {
                complete: true,
                ..Default::default()
            }
        ),
        BTreeSet::from(["mono".into()])
    );
    assert!(r.output_paths.contains("/roms/ports/Space Game/log.txt"));
    assert!(!r.paths.contains("/roms/ports/Space Game/log.txt"));
    assert!(!r.output_paths.iter().any(|p| p.ends_with("/1")));
}

fn analyze_fixture(source: &str, env: &SnapshotEnvironment) -> PathAnalysis {
    analyze_with_environment(
        source,
        &BTreeMap::from([
            ("directory".into(), "/roms".into()),
            ("HOME".into(), "/root".into()),
            ("LD_LIBRARY_PATH".into(), "".into()),
        ]),
        Path::new("/roms/ports/中文.sh"),
        env,
    )
}

#[test]
fn recursive_txt_source_shares_variables_functions_and_restores_positionals() {
    let env=SnapshotEnvironment{files:BTreeMap::from([
        (PathBuf::from("/pm/control.txt"),"CFW_NAME=test\nsource /pm/nested.txt\nchoose() { local X=/ignore; GAME=\"$1\"; }\n".into()),
        (PathBuf::from("/pm/nested.txt"),"BASE=/roms/ports\n".into()),
        (PathBuf::from("/pm/mod_test.txt"),"choose \"$BASE/游戏\"\n".into()),
    ]),complete:true,..Default::default()};
    let result = analyze_fixture(
        "source /pm/control.txt\nsource /pm/mod_${CFW_NAME}.txt\ncd \"$GAME\"\n",
        &env,
    );
    assert!(!result.uncertain(), "{:?}", result);
    assert_eq!(result.sources.len(), 3);
    assert!(result.working_directories.contains("/roms/ports/游戏"));
}

#[test]
fn unrelated_unknown_values_and_logging_do_not_poison_game_path() {
    let r = analyze_fixture(
        "NOISE=$(date)\nGAME=/roms/ports/foo\ncd \"$GAME\"\necho \"$NOISE\" > \"$GAME/log.txt\"\n",
        &SnapshotEnvironment::default(),
    );
    assert!(!r.uncertain(), "{:?}", r);
    assert!(r.output_paths.contains("/roms/ports/foo/log.txt"));
    assert!(!r.paths.contains("/roms/ports/foo/log.txt"));
}

#[test]
fn substitutions_keep_file_references_even_after_an_unknown_string_part() {
    let r = analyze_fixture(
        "NOTE=\"$UNKNOWN $(cat /roms/ports/shared/data.txt)\"\ncd /roms/ports/game\n",
        &SnapshotEnvironment::default(),
    );
    assert!(r.paths.contains("/roms/ports/shared/data.txt"));
    assert!(r.working_directories.contains("/roms/ports/game"));
}

#[test]
fn variable_and_source_byte_limits_fail_closed() {
    let source = (0..2100).map(|n| format!("V{n}=x\n")).collect::<String>();
    assert!(analyze_fixture(&source, &SnapshotEnvironment::default()).uncertain());
    let env = SnapshotEnvironment {
        files: BTreeMap::from([(
            PathBuf::from("/large.txt"),
            "x".repeat(crate::shell_sources::MAX_FILE_BYTES + 1),
        )]),
        ..Default::default()
    };
    assert!(analyze_fixture("source /large.txt", &env).uncertain());
}

#[test]
fn uncertain_defaults_and_combined_redirects_do_not_hide_source_changes() {
    let env = SnapshotEnvironment {
        files: BTreeMap::from([(PathBuf::from("/helper.txt"), "cd /roms/ports/old".into())]),
        ..Default::default()
    };
    assert!(
        analyze_fixture(
            "NOTE=${UNKNOWN:-$(touch /helper.txt)}\nsource /helper.txt",
            &env
        )
        .uncertain()
    );
    assert!(analyze_fixture("echo changed >& /helper.txt\nsource /helper.txt", &env).uncertain());
    assert!(
        analyze_fixture("GAME=''\nOTHER=${GAME:=$UNKNOWN}\ncd \"$GAME/data\"", &env).uncertain()
    );
}

#[test]
fn dependency_on_unknown_value_and_divergent_branches_remains_unknown() {
    let env = SnapshotEnvironment::default();
    assert!(analyze_fixture("BASE=$(date)\ncd \"$BASE/game\"", &env).uncertain());
    assert!(
        analyze_fixture(
            "if [ -d /unknown ]; then GAME=/a; else GAME=/b; fi\ncd \"$GAME\"",
            &env
        )
        .uncertain()
    );
    let r = analyze_fixture(
        "if [ -d /unknown ]; then NOISE=a; else NOISE=b; fi\ncd /roms/ports/foo",
        &env,
    );
    assert!(!r.uncertain(), "{:?}", r);
}

#[test]
fn known_device_file_selects_one_branch() {
    let env = SnapshotEnvironment {
        directories: [PathBuf::from("/card2")].into(),
        complete: true,
        ..Default::default()
    };
    let r = analyze_fixture(
        "if [ -d /card1 ]; then GAME=/card1/game; elif [ -d /card2 ]; then GAME=/card2/game; else GAME=/wrong; fi\ncd \"$GAME\"",
        &env,
    );
    assert!(!r.uncertain(), "{:?}", r);
    assert_eq!(r.working_directories, ["/card2/game".into()].into());
    let r = analyze_fixture(
        "if false; then GAME=/wrong; elif false; then GAME=/wrong2; elif false; then GAME=/wrong3; else GAME=/fallback; fi\ncd \"$GAME\"",
        &env,
    );
    assert!(!r.uncertain(), "{r:#?}");
    assert_eq!(r.working_directories, ["/fallback".into()].into());
}

#[test]
fn libraries_inputs_and_wrapped_commands_are_separate() {
    let r = analyze_fixture(
        "GAME=/roms/ports/foo\ncd \"$GAME\"\nexport LD_LIBRARY_PATH=\"$GAME/libs:/opt/shared:\"\nexport LD_PRELOAD=\"$GAME/hook.so libsystem.so\"\nRUN=\"env LD_LIBRARY_PATH=/runtime/lib /runtime/game\"\n$RUN \"$GAME/data\"\nGPTOKEYB=/pm/gptokeyb\n$GPTOKEYB game -c ./keys.gptk\n",
        &SnapshotEnvironment::default(),
    );
    assert!(!r.uncertain(), "{:?}", r);
    for p in [
        "/roms/ports/foo/libs",
        "/opt/shared",
        "/roms/ports/foo",
        "/runtime/lib",
    ] {
        assert!(r.library_paths.contains(p), "{p}: {r:?}");
    }
    assert!(r.preload_libraries.contains("libsystem.so"));
    assert!(r.input_configs.contains("/roms/ports/foo/keys.gptk"));
    assert!(!r.paths.iter().any(|p| p.contains("LD_LIBRARY_PATH=")));
}

#[test]
fn cycles_missing_sources_and_function_recursion_fail_closed() {
    let env = SnapshotEnvironment {
        files: BTreeMap::from([
            (PathBuf::from("/a.txt"), "source /b.txt".into()),
            (PathBuf::from("/b.txt"), "source /a.txt".into()),
        ]),
        ..Default::default()
    };
    assert!(analyze_fixture("source /a.txt", &env).uncertain());
    assert!(analyze_fixture("source /missing.txt\ncd /roms/ports/foo", &env).uncertain());
    assert!(analyze_fixture("f() { f; }; f", &env).uncertain());
}

#[cfg(unix)]
#[test]
fn host_source_loader_rejects_symlinks_traversal_and_non_scripts() {
    use crate::shell_sources::{FileEnvironment, SourceEnvironment};
    use std::os::unix::fs::symlink;
    let t = tempfile::tempdir().unwrap();
    let root = t.path().join("allowed");
    std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join("safe.txt"), "X=ok").unwrap();
    std::fs::write(t.path().join("outside.txt"), "secret").unwrap();
    symlink(t.path().join("outside.txt"), root.join("link.txt")).unwrap();
    let env = FileEnvironment::new([root.clone()]);
    assert_eq!(env.read(&root.join("safe.txt")).unwrap(), "X=ok");
    for p in [
        root.join("link.txt"),
        root.join("../outside.txt"),
        root.join(".env"),
    ] {
        assert!(env.read(&p).is_err());
    }
}

fn official_fixture() -> (SnapshotEnvironment, BTreeMap<String, String>) {
    let root = PathBuf::from(std::env::var_os("PM_CONTROL_CORPUS").unwrap());
    let mut env = SnapshotEnvironment {
        complete: true,
        ..Default::default()
    };
    fn load(base: &Path, dir: &Path, env: &mut SnapshotEnvironment) {
        for e in std::fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let kind = e.file_type().unwrap();
            if kind.is_dir() {
                load(base, &e.path(), env);
            } else if kind.is_file()
                && (e.path().extension().is_some_and(|x| x == "txt")
                    || e.file_name() == "tasksetter")
            {
                let logical =
                    Path::new("/roms/ports/PortMaster").join(e.path().strip_prefix(base).unwrap());
                env.files
                    .insert(logical, std::fs::read_to_string(e.path()).unwrap());
            }
        }
    }
    load(&root, &root, &mut env);
    env.commands
        .insert("sudo echo \"Testing for sudo...\"".into(), String::new());
    env.statuses.insert("command -v taskset".into(), false);
    let mut vars = BTreeMap::from([
        ("directory".into(), "roms".into()),
        ("controlfolder".into(), "/roms/ports/PortMaster".into()),
        ("HOME".into(), "/root".into()),
        ("XDG_DATA_HOME".into(), "".into()),
        ("LD_LIBRARY_PATH".into(), "".into()),
        ("DEVICE_INFO_VERSION".into(), "offline-initialized".into()),
        ("CFW_NAME".into(), "TrimUI".into()),
        ("DEVICE_ARCH".into(), "aarch64".into()),
        ("PM_FUNCS_VERSION".into(), "".into()),
        ("PM_SCRIPTNAME".into(), "".into()),
        ("PM_PORTNAME".into(), "".into()),
        ("PM_CAN_MOUNT".into(), "Y".into()),
        ("OS_NAME".into(), "TrimUI".into()),
        ("DISPLAY_WIDTH".into(), "1280".into()),
        ("DISPLAY_HEIGHT".into(), "720".into()),
        ("PM_PIPE".into(), "".into()),
    ]);
    for key in [
        "PYSDL2_DLL_PATH",
        "SDL_VIDEODRIVER",
        "SDL_VIDEO_GL_DRIVER",
        "SDL_VIDEO_EGL_DRIVER",
        "SDL_DYNAMIC_API",
        "SDL_OPENGL_DRIVER",
        "SDL_RENDER_DRIVER",
        "SDL_NO_OPENGL",
    ] {
        vars.insert(key.into(), String::new());
    }
    (env, vars)
}

#[test]
#[ignore = "requires PM_CONTROL_CORPUS and PM_SHELL_CORPUS official snapshots"]
fn official_goldminer_source_graph() {
    let (env, vars) = official_fixture();
    let path =
        PathBuf::from(std::env::var_os("PM_SHELL_CORPUS").unwrap()).join("goldminer/Gold Miner.sh");
    let r = analyze_with_environment(
        &std::fs::read_to_string(path).unwrap(),
        &vars,
        Path::new("/roms/ports/黄金矿工.sh"),
        &env,
    );
    println!("{r:#?}");
    assert!(r.working_directories.contains("/roms/ports/goldminer"));
    assert!(
        r.input_configs
            .contains("/roms/ports/goldminer/goldminer.gptk")
    );
    assert!(
        r.library_paths
            .contains("/roms/ports/PortMaster/runtimes/love_11.5/libs.aarch64")
    );
    assert!(r.sources.iter().any(|p| p.ends_with("device_info.txt")));
    assert!(
        r.runtime_dependencies(Some(Path::new("/roms/ports/PortMaster/libs")), &env)
            .is_empty()
    );
    assert!(!r.uncertain(), "{:?}", r.diagnostics);
}

#[test]
#[ignore = "requires official snapshots; device facts below are synthetic, not a real device capture"]
fn official_cold_device_detection_selects_cfw_and_architecture() {
    let (mut env, mut vars) = official_fixture();
    vars.insert("DEVICE_INFO_VERSION".into(), String::new());
    vars.insert("CFW_NAME".into(), String::new());
    vars.insert("DEVICE_ARCH".into(), String::new());
    vars.insert("PM_VERSION".into(), String::new());
    env.directories.insert(PathBuf::from("/usr/trimui"));
    env.files
        .insert(PathBuf::from("/etc/version"), "offline-fixture".into());
    env.files
        .insert(PathBuf::from("/lib/ld-linux-aarch64.so.1"), String::new());
    for name in ["knulli-version", "batocera-version", "system-version"] {
        env.commands
            .insert(format!("$(which {name})"), String::new());
    }
    env.commands.insert("$(uname -i)".into(), "aarch64".into());
    env.commands.insert(
        "$(echo \"$DEVICE_NAME\" | tr '[:upper:]' '[:lower:]')".into(),
        "trimui smart pro".into(),
    );
    let path =
        PathBuf::from(std::env::var_os("PM_SHELL_CORPUS").unwrap()).join("goldminer/Gold Miner.sh");
    let r = analyze_with_environment(
        &std::fs::read_to_string(path).unwrap(),
        &vars,
        Path::new("/roms/ports/黄金矿工.sh"),
        &env,
    );
    println!("COLD_DEVICE {:?}", r.diagnostics);
    assert!(
        r.sources.contains("/roms/ports/PortMaster/mod_TrimUI.txt"),
        "{r:#?}"
    );
    assert!(
        r.library_paths
            .contains("/roms/ports/PortMaster/runtimes/love_11.5/libs.aarch64"),
        "{r:#?}"
    );
    // CFW/architecture are resolved without inventing a CPU/arithmetic result.
    // The complete cold-start helper also contains unmodeled arithmetic loops.
    assert!(r.uncertain());
}

#[test]
#[ignore = "requires pinned PM_CONTROL_CORPUS, PM_SHELL_CORPUS and PM_METADATA_CORPUS snapshots"]
fn official_corpus_with_sources_and_independent_metadata() {
    let root = PathBuf::from(std::env::var_os("PM_SHELL_CORPUS").unwrap());
    let metadata = PathBuf::from(std::env::var_os("PM_METADATA_CORPUS").unwrap());
    let (base_environment, vars) = official_fixture();
    let mut scripts = Vec::new();
    fn visit(dir: &Path, scripts: &mut Vec<PathBuf>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let kind = e.file_type().unwrap();
            if kind.is_dir() {
                visit(&e.path(), scripts);
            } else if kind.is_file()
                && e.path()
                    .extension()
                    .is_some_and(|x| x.eq_ignore_ascii_case("sh"))
            {
                scripts.push(e.path());
            }
        }
    }
    visit(&root, &mut scripts);
    scripts.sort();
    let mut total = 0;
    let mut complete = 0;
    let mut metadata_checked = 0;
    let mut data_hit = 0;
    let mut complete_without_metadata_hit = Vec::new();
    let mut without_metadata_hit = Vec::new();
    let mut diagnostics = BTreeMap::<String, usize>::new();
    let mut libraries = 0;
    let mut inputs = 0;
    let mut sourced = 0;
    let mut top_level = 0;
    let mut keyboard_files = 0;
    let mut runtime_locations = 0;
    for script in &scripts {
        let mut env = base_environment.clone();
        let relative = script.strip_prefix(&root).unwrap();
        top_level += usize::from(relative.components().count() == 2);
        let package = relative.components().next().unwrap().as_os_str();
        let json = metadata.join(package).join("port.json");
        fn load_package(base: &Path, dir: &Path, env: &mut SnapshotEnvironment) {
            for e in std::fs::read_dir(dir).unwrap() {
                let e = e.unwrap();
                let kind = e.file_type().unwrap();
                if kind.is_dir() {
                    load_package(base, &e.path(), env);
                } else if kind.is_file()
                    && (e
                        .path()
                        .extension()
                        .is_some_and(|x| x == "txt" || x == "inc" || x == "sh")
                        || e.file_name() == "fallback")
                {
                    let logical =
                        Path::new("/roms/ports").join(e.path().strip_prefix(base).unwrap());
                    env.files
                        .insert(logical, std::fs::read_to_string(e.path()).unwrap());
                }
            }
        }
        let package_root = metadata.join(package);
        load_package(&package_root, &package_root, &mut env);
        let items = std::fs::read(&json)
            .ok()
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| v["items"].as_array().cloned())
            .unwrap_or_default();
        let roots = items
            .iter()
            .filter_map(|v| v.as_str())
            .filter(|s| !s.to_ascii_lowercase().ends_with(".sh"))
            .map(|s| Path::new("/roms/ports").join(s.trim_end_matches('/')))
            .collect::<Vec<_>>();
        for path in &roots {
            env.directories.insert(path.clone());
        }
        let logical =
            Path::new("/roms/ports").join(relative.components().skip(1).collect::<PathBuf>());
        let source = std::fs::read_to_string(script).unwrap();
        let r = analyze_with_environment(&source, &vars, &logical, &env);
        let dependencies =
            r.runtime_dependencies(Some(Path::new("/roms/ports/PortMaster/libs")), &env);
        // This synthetic corpus has no filesystem aliases. Compare exact image
        // locations, not just a nonzero count; bundled runtimes must not leak in.
        let expected = r
            .paths
            .iter()
            .chain(&r.declared_paths)
            .chain(&r.sources)
            .filter_map(|path| path.strip_prefix("/roms/ports/PortMaster/libs/"))
            .filter_map(|name| name.strip_suffix(".squashfs"))
            .filter(|name| !name.contains('/') && !name.is_empty())
            .map(str::to_owned)
            .collect::<BTreeSet<_>>();
        assert_eq!(
            dependencies,
            expected,
            "Runtime image association: {}",
            relative.display()
        );
        runtime_locations += usize::from(!dependencies.is_empty());
        total += 1;
        complete += usize::from(!r.uncertain());
        libraries += usize::from(!r.library_paths.is_empty() || !r.preload_libraries.is_empty());
        inputs += usize::from(!r.input_configs.is_empty());
        keyboard_files += usize::from(r.input_configs.iter().any(|p| p.ends_with(".gptk")));
        sourced += usize::from(!r.sources.is_empty());
        if !roots.is_empty() {
            metadata_checked += 1;
            let hit = r
                .paths
                .iter()
                .chain(&r.declared_paths)
                .any(|p| roots.iter().any(|root| Path::new(p).starts_with(root)));
            data_hit += usize::from(hit);
            if !hit {
                without_metadata_hit.push(relative.display().to_string());
            }
            if !hit && !r.uncertain() {
                complete_without_metadata_hit.push(relative.display().to_string());
            }
        }
        let reasons = r
            .diagnostics
            .iter()
            .map(|issue| {
                let reason = issue.split_once(": ").map_or(issue.as_str(), |(_, s)| s);
                reason
                    .split_once(" at line ")
                    .map_or(reason, |(r, _)| r)
                    .to_owned()
            })
            .collect::<BTreeSet<_>>();
        for reason in reasons {
            *diagnostics.entry(reason.into()).or_default() += 1;
        }
        for path in &roots {
            env.directories.remove(path);
        }
    }
    println!("RUNTIME_LOCATION_SCRIPTS {runtime_locations}");
    assert!(
        runtime_locations > 0,
        "official Runtime path evidence was lost"
    );
    println!(
        "OFFICIAL_CORPUS {}",
        serde_json::json!({"scripts":total,"top_level_launchers":top_level,"path_analysis_complete":complete,"metadata_checked":metadata_checked,"metadata_data_root_hit":data_hit,"without_metadata_hit":without_metadata_hit,"complete_without_metadata_hit":complete_without_metadata_hit,"with_library_evidence":libraries,"with_input_evidence":inputs,"with_gptk_file":keyboard_files,"with_sources":sourced,"diagnostics":diagnostics})
    );
    assert_eq!(
        total, 1445,
        "expected pinned official corpus, not an accidental subset"
    );
    assert!(metadata_checked > 1400, "official metadata missing");
}
