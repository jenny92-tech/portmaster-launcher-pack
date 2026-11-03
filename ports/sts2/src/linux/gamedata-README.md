# Game resource preparation

Players must own a legal copy of *Slay the Spire 2*. The launcher source and
stock launcher assembly exclude game content. Keep original files read-only and
prepare converted data in a separate private directory.

## Supported inputs

Preparation accepts the exact inputs recorded by the port's reviewed profiles:

- Prepared ARM64/Mali data: `src/tools/handheld_low_profile.json`.
- Windows v0.110.1 data: `src/tools/handheld_low_v110_profile.json`.

A matching version label alone is insufficient: the tools verify the original
PCK, game assembly, dependency graph and Linux baseline by content identity.
Another game build requires a new review of its resource and managed-code
contracts. Do not bypass validation by changing checksums.

The source repository's `ports/sts2/DEVELOPMENT.md` lists dependencies and the
`optimize_handheld.py build` / `build-windows` commands. Resource conversion
requires official stable Godot 4.5.1; the handheld's RC/custom runtime is a
separate input. Windows preparation also needs the matched Linux runtime deps
and GodotSharp described there.

## What must be prepared

| Component | Required handling |
|---|---|
| `sts2.dll` | Check the reviewed assembly identity and pure-IL/architecture flags before conversion |
| Game-supplied dependencies | Inspect every dependency, including Steamworks; do not assume all exports are AnyCPU |
| `sts2.deps.json` | Produce a matched Linux ARM64 dependency graph using the preparation tools |
| Main PCK and resource overlays | Convert supported desktop texture formats, preserve logical dimensions and protected data resources, then validate the merged pack |
| Native extensions and .NET runtime | Use the matched Linux ARM64 binaries and retain their license/provenance notices |

Changing a PE Machine field does not translate native x64 code. BC texture
conversion, import mappings, shaders, extension ABI and managed dependencies are
independent requirements. Follow the complete reviewed pipeline rather than
manually copying a fixed number of DLLs or using package size as validation.

## Assembly layout

The stock SDL assembly uses this resource convention:

```text
gamedata/
├── data_sts2_linuxbsd_arm64/
│   ├── sts2.dll
│   ├── sts2.deps.json
│   └── <matched game dependencies>
└── pcks/
    └── SlayTheSpire2.pck
```

Verified installed profiles can use a different layout with a bound
`active-build` selector. Use that profile's installer and generated inventory;
do not move its main pack or dependencies by hand. The launcher, runtime and
prepared game data must belong to the same reviewed set.

## Verification and troubleshooting

- Missing PCK or assembly: check the generated inventory and the profile's
  actual resource directory. Preserve the original game input.
- `FileLoadException` / `BadImageFormatException`: inspect the game assembly
  and all dependencies for version and architecture mismatches. Re-run the
  reviewed preparation pipeline; a blind PE-header edit is not a general fix.
- Runtime or device rejected: check the supported graphics profiles in the
  source repository's `ports/sts2/README.md`
  and matched engine/extension identities. A similar SoC name is not validation.

Save build reports privately with the converted resources. Resource preparation
and host checks do not certify handheld memory usage, text appearance, input,
combat or normal exit. Actual device support is documented in the port README.

Game files, reconstructed projects and game-derived overlays are excluded from
public source releases. Third-party components retain their own licenses; the
project's launcher license grants no rights to distribute the game.
