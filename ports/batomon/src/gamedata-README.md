# Batomon game data

Place the prepared game pack here:

```
gamedata/
└── batomon_showdown.pck
```

The Windows demo ships `batomon_showdown.pck`, but that file is encrypted and
its GodotSteam extension config only lists desktop libraries. For handheld use,
prepare an unencrypted PCK with the repo helper:

```bash
ports/batomon/src/scripts/prepare-batomon-pck.py \
  --input "/path/to/Batomon Showdown Demo/batomon_showdown.pck" \
  --output ports/batomon/dist/gamedata/batomon_showdown.pck \
  --key "$BATOMON_PCK_KEY" \
  --patch-godotsteam-arm64
```

Expected runtime side files are supplied by the launcher pack:

```
addons/godotsteam/linuxarm64/libgodotsteam.linux.template_release.arm64.so
addons/godotsteam/linuxarm64/libsteam_api.so
libsteam_api64.so
```
