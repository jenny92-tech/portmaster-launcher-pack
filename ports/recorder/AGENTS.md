# 独立录屏端口

> 在掌机后台采集屏幕帧，并在停止后合成为视频。

## 地位

ports/ 下的 Screen Recorder 原型应用，同时支持 TrimUI APP 与 PortMaster 包装。

## 逻辑

love/ 界面调用 portable/ 中的录屏 CLI；引擎借助 ffmpeg kmsgrab 采帧，停止时合成 MP4，包元数据负责路径和图标包装。

## 约束

- portable/bin/record_screen.sh 由 `_kit/build_recorder_tool.sh` 从 `_kit/recorder.sh` 生成，不直接编辑。
- bundled ffmpeg 和生成 dist/ 不是源码；文档初始化不重建、部署或启动采帧。
- 游戏运行时只采帧，停止后再编码；界面退出不会自动停止录屏。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 应用身份、双入口包装、runtime 与便携资源配置 |
| 使用说明 | `README.md` | 录制方式、设备限制与使用说明 |
| 授权 | `LICENSE` | 应用授权声明 |
| 预览图 | `screenshot.png` | 发行包应用截图 |
| 录屏界面 | `love/` | CLI 控制和状态展示，见子目录 AGENTS.md |
| 录屏工具 | `portable/` | 生成的独立录屏 CLI 与 bundled ffmpeg |
| TrimUI 图标 | `trimui-app/` | 原生应用包装图标 |
