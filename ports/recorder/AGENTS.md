# 独立录屏端口

Screen Recorder 将共享录屏引擎包装成 PortMaster Port 和 TrimUI App。界面通过生成的 record_screen.sh 控制后台采帧，并在停止后合成 MP4；端口只负责控制、状态显示及安装布局，采帧和编码实现位于 `_kit/recorder.sh`。

## 约束

- portable/bin/record_screen.sh 由 `_kit/build_recorder_tool.sh` 从 `_kit/recorder.sh` 生成，不直接编辑。
- bundled FFmpeg 和 dist/ 是构建产物，分别由共享构建与端口打包流程维护。
- 游戏运行时只采帧，停止后再编码；界面退出不会自动停止录屏。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | Port/TrimUI 双入口、路径与运行依赖 |
| 使用说明 | `README.md` | 录制方式、设备限制与使用说明 |
| 授权 | `LICENSE` | 应用授权声明 |
| 启动器封面 | `screenshot.png` | 端口预览及启动封面来源 |
| 录屏界面 | `love/` | CLI 控制、帧数轮询及合成结果 |
| 录屏工具 | `portable/` | 生成的录屏 CLI 与 FFmpeg 运行时 |
| TrimUI 图标 | `trimui-app/` | 原生应用包装图标，使用同款圆角细边框与紫猫角底 |
