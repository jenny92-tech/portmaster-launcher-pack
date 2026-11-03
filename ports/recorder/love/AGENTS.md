# 录屏应用界面

模板先配置 REC_ENGINE、REC_DIR 和 PortMaster UI 环境，`main.lua` 再向录屏 CLI 发送 start/stop/status。页面退出只结束 UI；录制会话和停止后的 MP4 合成由独立引擎持有。

## 约束

- 退出界面不等于停止后台采帧；停止按钮才负责停止并合成。
- UI 依赖 PortMaster 提供 LÖVE runtime、字体和 gptokeyb。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 录屏页面 | `main.lua` | start/stop/status 调用、帧数刷新与结果显示 |
| 启动模板 | `launcher.sh.template` | 定位引擎/录制目录并启动 LÖVE 页面 |
