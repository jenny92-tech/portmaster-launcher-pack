# Launcher Pack Manifest

Reference layout and component origins for the complete launcher assembly
(`dist-sts2-<date>.zip`). Verified installed handheld profiles may use a different
layout. Check the generated inventory and each component's license before distribution.

The pack assembles via `src/scripts/assemble-launcher-pack.sh`.
The bundled KMSDRM SDL2 in `gamedata/libs/` builds via
`src/scripts/build_bundled_sdl.sh` (zlib license, see SDL upstream).

## Layout

```
dist/
├── <manifest script>.sh                        [our] launcher.sh (named by manifest.json "script")
├── godot.mono                                  [our fork CI]
├── love_ui/                                    [our build]
│   ├── kit.lua                                 [our shared UI]
│   ├── main.lua / conf.lua / ui.gptk           [our port UI]
│   └── launcher_bg.png                         [our shared art]
├── port_compat.pck                             [our build]
├── libsteam_api64.so                           [our stub]
├── input_remap.cfg                             [our template]
├── data_sts2_linuxbsd_arm64/
│   ├── sts2_compat.dll                         [our build]
│   ├── sts2.runtimeconfig.json                 [our template]
│   ├── GodotSharp.dll                          [our fork CI]
│   ├── 0Harmony.dll                            [NuGet MIT]
│   ├── System.Private.CoreLib.dll              [Microsoft .NET 9 BCL]
│   ├── ... (~100 System.*.dll + *.so)          [Microsoft .NET 9 BCL]
│   ├── Microsoft.CSharp.dll                    [Microsoft .NET 9 BCL]
│   ├── ... (~5 Microsoft.*.dll)                [Microsoft .NET 9 BCL]
│   ├── mscorlib.dll / netstandard.dll          [Microsoft .NET 9 BCL]
│   ├── WindowsBase.dll                         [Microsoft .NET 9 BCL]
│   └── System.IO.Hashing.dll                   [NuGet MIT, ships with .NET 9]
├── addons/
│   ├── fmod/libs/linux/
│   │   └── libGodotFmod.linux.template_release.arm64.so  [our fork CI]
│   ├── spine/linux/
│   │   └── libspine_godot.linux.template_release.arm64.so [our fork CI]
│   └── sentry/
│       └── SentryStub.gd                       [our stub]
└── gamedata/
    └── README.md                               [our tutorial; user fills the dir]
```

## Source / license breakdown

| Origin | License / authoritative notice | Components |
|---|---|---|
| Project code, templates and original assets | CC BY-NC-SA 4.0, see [port LICENSE](../../LICENSE); preserve any explicit per-file or upstream notice | sts2_compat.dll, original overlay code, launchers, UI and stubs |
| Godot fork | Godot MIT and bundled third-party notices | godot.mono, GodotSharp.dll |
| FMOD extension fork | Extension's upstream license; separate from the proprietary FMOD runtime | libGodotFmod |
| Spine fork | Esoteric Software Spine runtime license/EULA | libspine_godot |
| SDL2 | zlib license and bundled notices | Private KMSDRM SDL2 |
| Harmony / Microsoft runtime and packages | Each package's LICENSE / third-party notices | 0Harmony.dll, .NET BCL and native libraries |

Build provenance and expected filenames for native extensions are recorded in
`src/external/` (relative to the port root). Project licensing does not replace
third-party terms or establish permission to distribute an arbitrary assembled pack.

## What's NOT in the pack (player provides via gamedata/)

| File | License | Source |
|---|---|---|
| `sts2.dll` | Game license | Player-owned install; pure-IL/architecture checks before conversion |
| `sts2.deps.json` | Game distribution's notices | Player-owned install; RID rewrite |
| Game-supplied .NET dependencies | Each dependency's license | Matched player input; inspect each assembly's architecture |
| `SlayTheSpire2.pck` and rebuilt game resources | Game and embedded-resource licenses | Player-owned input, private resource preparation |
| FMOD runtime `.so` files | FMOD EULA | Player-provided separately from the extension |

Player follows `gamedata/README.md` to produce these.

## License posture

The public launcher source and stock assembly exclude game files and proprietary
FMOD runtimes. Player-built resource overlays can contain game-derived data and
must remain private. Preserve project attribution, non-commercial/share-alike
terms and every third-party notice applicable to the actual payload. The license
table is a navigation aid, not a blanket redistribution grant.

## Verification

After `src/scripts/assemble-launcher-pack.sh` produces the zip:

```bash
unzip -l dist-sts2-*.zip
```

Compare the archive with its generated build inventory, source revisions and
checksums. Confirm that no game input, save, cache, private report or restricted
runtime was collected. File counts and compressed size alone do not establish
payload identity or redistribution rights.
