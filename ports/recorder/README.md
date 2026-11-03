# Je-Screen Recorder (Je-录屏助手)

Standalone handheld screen recorder. The TrimUI Brick has no HDMI/DP video
output, so the only viable recording path is internal: grab the DRM scanout
plane (ffmpeg `kmsgrab`) at a low framerate into JPEG frames, then assemble
the frames into an MP4 afterwards.

- While the game runs, capture JPEG frames at 5 fps; x264 encoding runs after stop.
- **Standalone app**: lives in `Apps/` as a TrimUI MainUI APP. It does not
  modify any game launcher; start recording, play any game, stop recording.
- Requires PortMaster (for the LÖVE 11.5 runtime, shared font and gptokeyb).

## Install (TrimUI Brick)

```bash
_kit/dist_trimui_app.sh recorder          # → dist/[TrimUI App] Je-录屏助手.zip
```

Copy the zip to the SD card, extract it into `Apps/` (or install through
APP Manager). The app also packages as a PortMaster port
(`_kit/dist_port.sh recorder`).

## Usage

1. Open Je-录屏助手 → **Start Recording** → press B to return to the menu.
2. Launch and play any game. Recording continues in the background
   (the capture process is detached via `setsid`).
3. Open Je-录屏助手 again → **Stop & Assemble** → the MP4 is written next to the
   frame session under `/mnt/SDCARD/videos/`.

During a game the recorded footage includes everything the panel shows, so a
recording typically starts with the frontend, covers the game, and ends when
you return to the frontend.

## Files

| Path | Purpose |
|---|---|
| `Je-Screen Recorder.sh` | Assembled app launcher (LÖVE UI + engine). |
| `jenny92-screenrec/love_ui/` | LÖVE UIKit + recorder pages (`main.lua`). |
| `jenny92-screenrec/bin/record_screen.sh` | Engine CLI (status/start/stop/assemble). |
| `jenny92-screenrec/bin/ffmpeg` | Minimal static aarch64 ffmpeg (kmsgrab + mjpeg + libx264). |
| `jenny92-screenrec/bin/portkit-launcher` | PortMaster runtime/font helper. |

## Engine (SSH / verification)

The engine is a self-contained CLI (`tools/record_screen.sh`, generated from
`_kit/recorder.sh` by `_kit/build_recorder_tool.sh`). To verify kmsgrab works
on the device before installing the app:

```bash
# copy the tool + recorder ffmpeg to the device, then over SSH:
./record_screen.sh probe    # ffmpeg/kmsgrab/DRM card/output dir facts
./record_screen.sh start    # begin 5 fps capture
# ... play a game ...
./record_screen.sh stop     # stop + assemble MP4
```

Environment knobs: `REC_FPS` (capture rate), `REC_Q` (JPEG quality),
`REC_FORMAT` (hwdownload format, default `bgr0`), `REC_DIR` (output root),
`REC_PRESET`/`REC_CRF` (x264 assembly quality), `REC_DRM_DEVICE`,
`REC_FFMPEG`, `REC_KEEP_FRAMES=1` (delete frames after successful assembly; default keeps them).

## Build

```bash
_kit/build_ffmpeg_recorder.sh    # static aarch64 ffmpeg → _kit/runtime/
_kit/build_recorder_tool.sh      # regenerate tools/record_screen.sh
_kit/dist_port.sh recorder       # dist/ payload (PortMaster layout)
_kit/dist_trimui_app.sh recorder # [TrimUI App] zip for Apps/
```

## Known limits

- Default 5 fps capture is intended for recording/debug journals; `REC_FPS`
  changes capture rate, not the capture-then-encode workflow.
- No audio capture yet.
- Stop-and-assemble blocks the UI until encoding completes; duration depends on session length.
