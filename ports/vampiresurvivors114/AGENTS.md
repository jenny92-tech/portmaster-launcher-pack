# 吸血鬼幸存者 1.14 端口

此端口把吸血鬼幸存者 1.14 的 LÖVE 设置接入 Unity 6/PAD 运行链。love 输出 VS_* 参数，并在模板中协调前端显示、Mali GL 配置与原生库路径；Android/PAD 资源实际解析由引擎插件负责。

## 约束

- PAD/Android 资源解析留在 UnityLoader 插件；不要在启动器复制该逻辑。
- 游戏阶段使用 Rudroid 原生 Android gamepad 输入及退出流程；gptokeyb 仅用于 LÖVE 设置 UI，不再启动第二套游戏键盘映射或外部强杀器。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 1.14 版本、Unity/PAD 依赖和安装身份 |
| 使用说明 | `README.md` | APK/PAD 资源准备及设备兼容范围 |
| 授权 | `LICENSE` | 端口授权声明 |
| 预览图 | `screenshot.png` | 保留横版原图尺寸与构图，使用统一圆角细边框与右下紫猫角底 |
| 启动界面 | `love/` | VS_* 字段、前端显示交接与游戏配置 |
