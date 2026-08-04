# Vampire Survivors 1.14.111 Port

This port runs the Android Unity 6 / IL2CPP build through Bogodroid's standard
`unityloader`. Unity, Google Play, GMS, asset-pack and game-specific behavior is
provided by independent plugins in `unityloader.d/`. It is intentionally kept
separate from newer Vampire Survivors builds.

## Device Layout

Installed layout:

```text
/mnt/SDCARD/Data/ports/vampiresurvivors114/
  launcher.sh
  manifest.json
  unityloader
  runtime/
    libstdc++.so.6
    libgcc_s.so.1
  unityloader.d/
    android_base.so
    platform_android_asset_packs.so
    platform_sdl_runtime.so
    sdk_fmod.so
    sdk_google_gms.so
    sdk_google_play_core.so
    sdk_unity_burst.so
    unity_6.so
  config.toml
  love_ui/
  gamedata/
    lib/arm64-v8a/*.so
    assets/...
    assetpacks/UnityDataAssetPack/assets/...

/mnt/SDCARD/Roms/PORTS/
  V_吸血鬼幸存者_114.sh
```

`config.toml` must point `paths.game_files` at the Android payload root and
select the writable, per-launch shader cache prepared by the launcher:

```toml
[paths]
game_files = "gamedata"
unity_shader_cache_redirect = "/tmp/bogodroid-cache-com.poncle.vampiresurvivors/UnityShaderCache"
```

Bogodroid changes cwd into `game_files`, so Android-style paths are resolved
relative to `gamedata/`. Shader-cache redirection is a generic loader config;
Vampire Survivors no longer needs a game-specific cache plugin.

## Build The Payload From An APK/APKS

1. Extract the base APK.
2. Copy base native libraries:

```text
base/lib/arm64-v8a/*.so
  -> gamedata/lib/arm64-v8a/
```

3. Copy base APK assets:

```text
base/assets/*
  -> gamedata/assets/
```

4. Extract the Play Asset Delivery pack named `UnityDataAssetPack`.
5. Copy the pack assets exactly under:

```text
UnityDataAssetPack/assets/*
  -> gamedata/assetpacks/UnityDataAssetPack/assets/
```

Do not merge the asset pack into `gamedata/assets`. Base assets and pack assets
can contain files with the same relative name, and Unity expects both views.

Expected important files:

```text
gamedata/assets/bin/Data/data.unity3d
gamedata/assets/bin/Data/Managed/Metadata/global-metadata.dat
gamedata/assetpacks/UnityDataAssetPack/assets/bin/Data/datapack.unity3d
gamedata/assetpacks/UnityDataAssetPack/assets/aa/settings.json
```

## Loader Requirements

Use the standard Bogodroid executable:

```text
unityloader
```

Place the required `.so` plugins in `unityloader.d/`. In particular,
`sdk_google_play_core.so` and `sdk_google_gms.so` enable their SDK stubs
independently; neither is coupled to `unity_6.so`. The plugin set handles:

- Google Play Games sign-in stubs.
- Play Asset Delivery completed-state/path stubs.
- Android base/split asset lookup through Java `AssetManager`.
- Android asset lookup through NDK `AAssetManager`.
- `open` / `fopen` fallback for Android asset paths.

No launcher-side bind mount is required for `assets` or `assets/aa`.

## Launcher

`love/launcher.sh.template` is the editable template. `_kit/dist_port.sh
vampiresurvivors114` writes the self-contained device script to
`dist/V_吸血鬼幸存者_114.sh` and stages the LÖVE files under `dist/love_ui/`;
the device never needs shared `_kit` scripts.

The LÖVE UI updates `vs.toml` through:

```text
love_ui/launch_config.env
```

On the first migrated launch, existing ABXY choices are imported from the old
Godot userdata env file. If the UI payload is absent, the script starts with the
current `vs.toml`.

The game stage intentionally does not run `gptokeyb`; Unity receives the
handheld buttons as Android gamepad events.

The launcher always resets `textureMaxDim` to `0`. This game uses offline asset
compression instead; runtime texture downscaling changes the apparent viewport.

## Resource Compression

Do not use `textureMaxDim` as the normal optimization path for this game. It can
change the apparent viewport and move the character off center.

Use offline ASTC re-tiering instead. The tested 1.14 pass was:

```bash
./tools/unity_astc/retier_all.sh "$GAME_DIR/gamedata" --keep-cap 768 --block 6x6
```

For the validated device payload, 38 files were replaced and about 187 MB were
saved.

## Deploy

Copy the standard loader, plugins and launcher atomically. The plugin source
directory below represents the matching Bogodroid build output:

```bash
scp build-release/unityloader \
  root@10.10.1.91:/mnt/SDCARD/Data/ports/vampiresurvivors114/unityloader.new
rsync -a --delete build-release/runtime/ \
  root@10.10.1.91:/mnt/SDCARD/Data/ports/vampiresurvivors114/runtime/
rsync -a --delete build-release/unityloader.d/ \
  root@10.10.1.91:/mnt/SDCARD/Data/ports/vampiresurvivors114/unityloader.d/
_kit/dist_port.sh vampiresurvivors114
scp ports/vampiresurvivors114/dist/V_吸血鬼幸存者_114.sh \
  root@10.10.1.91:/mnt/SDCARD/Data/ports/vampiresurvivors114/launcher.sh.new
scp ports/vampiresurvivors114/dist/V_吸血鬼幸存者_114.sh \
  root@10.10.1.91:/mnt/SDCARD/Roms/PORTS/V_吸血鬼幸存者_114.sh.new
rsync -a ports/vampiresurvivors114/dist/love_ui/ \
  root@10.10.1.91:/mnt/SDCARD/Data/ports/vampiresurvivors114/love_ui/

ssh root@10.10.1.91 'set -e
cd /mnt/SDCARD/Data/ports/vampiresurvivors114
chmod 755 unityloader.new launcher.sh.new
mv unityloader.new unityloader
mv launcher.sh.new launcher.sh
chmod 755 /mnt/SDCARD/Roms/PORTS/V_吸血鬼幸存者_114.sh.new
mv /mnt/SDCARD/Roms/PORTS/V_吸血鬼幸存者_114.sh.new /mnt/SDCARD/Roms/PORTS/V_吸血鬼幸存者_114.sh'
```

## Smoke Test

A good build should pass these points:

1. Launcher starts the game.
2. Logo advances.
3. Photosensitivity prompt accepts the confirm button.
4. Main menu opens.
5. Starting a run leaves the loading screen and enters gameplay.
