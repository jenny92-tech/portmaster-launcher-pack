# 录屏应用界面

> 通过独立录屏 CLI 控制后台采帧并展示录制状态。

## 地位

Screen Recorder 的交互层，可从 TrimUI APP 或 PortMaster 包启动。

## 逻辑

模板配置 PortMaster 和 REC_ENGINE/REC_DIR；Lua 页面调用 CLI 的 start、stop、status，周期刷新帧数并显示合成结果。

## 约束

- 采帧和视频合成由录屏引擎处理，界面不实现编码逻辑。
- 退出界面不等于停止后台采帧；停止按钮才负责停止并合成。
- UI 依赖 PortMaster 提供 LÖVE runtime、字体和 gptokeyb。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 录屏页面 | `main.lua` | 提供开始、停止合成、状态轮询和退出交互 |
| 启动模板 | `launcher.sh.template` | 识别应用路径，提供录屏环境并运行 UI |
