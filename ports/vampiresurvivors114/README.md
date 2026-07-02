# Vampire Survivors 1.14.111 Port

This port runs the Android Unity 6 / IL2CPP build through Bogodroid
`unityloader.gplay`. It is intentionally kept separate from newer Vampire
Survivors builds.

## Device Layout

Installed layout:

```text
/mnt/SDCARD/Data/ports/vampiresurvivors114/
  launcher.sh
  manifest.json
  unityloader.gplay
  vs.toml
  gamedata/
    lib/arm64-v8a/*.so
    assets/...
    assetpacks/UnityDataAssetPack/assets/...

/mnt/SDCARD/Roms/PORTS/
  V_吸血鬼幸存者_114.sh
```

`vs.toml` must point `paths.game_files` at the Android payload root:

```toml
[paths]
game_files = "gamedata"
```

Bogodroid changes cwd into `game_files`, so Android-style paths are resolved
relative to `gamedata/`.

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

Use a Bogodroid `unityloader` built with Google Play stubs enabled:

```text
unityloader.gplay
```

The loader handles:

- Google Play Games sign-in stubs.
- Play Asset Delivery completed-state/path stubs.
- Android base/split asset lookup through Java `AssetManager`.
- Android asset lookup through NDK `AAssetManager`.
- `open` / `fopen` fallback for Android asset paths.

No launcher-side bind mount is required for `assets` or `assets/aa`.

## Launcher

`launcher.sh` is self-contained and does not require shared `_kit` scripts on
the device.

If a Godot/frt launcher payload is present, it can update `vs.toml` through:

```text
conf/godot/app_userdata/Vampire Survivors Launcher/launch_config.env
```

If the UI payload is absent, the script starts with the current `vs.toml`.

The game stage intentionally does not run `gptokeyb`; Unity receives the
handheld buttons as Android gamepad events.

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

Copy the loader and launcher atomically:

```bash
scp build-release/unityloader \
  root@10.10.1.91:/mnt/SDCARD/Data/ports/vampiresurvivors114/unityloader.gplay.new
scp ports/vampiresurvivors114/launcher.sh \
  root@10.10.1.91:/mnt/SDCARD/Data/ports/vampiresurvivors114/launcher.sh.new
scp ports/vampiresurvivors114/launcher.sh \
  root@10.10.1.91:/mnt/SDCARD/Roms/PORTS/V_吸血鬼幸存者_114.sh.new

ssh root@10.10.1.91 'set -e
cd /mnt/SDCARD/Data/ports/vampiresurvivors114
chmod 755 unityloader.gplay.new launcher.sh.new
mv unityloader.gplay.new unityloader.gplay
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
