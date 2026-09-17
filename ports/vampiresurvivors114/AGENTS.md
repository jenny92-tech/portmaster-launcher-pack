# 吸血鬼幸存者 1.14 端口

> 使用 Bogodroid UnityLoader 运行 Unity 6 与 PAD 资源布局的游戏版本。

## 地位

ports/ 下依赖插件式 UnityLoader 的游戏端口，包含掌机显示所有权与 Mali 图形兼容适配。

## 逻辑

manifest 描述端口和运行依赖；love/ 输出 VS_* 选项，模板协调前端、更新图形和按键配置，再将游戏原生库路径交给共享启动器。

## 约束

- PAD/Android 资源解析留在 UnityLoader 插件；不要在启动器复制该逻辑。
- 游戏阶段保留 Android gamepad 输入；Rewired 1.14 的键盘桥只能使用独立游戏映射，不能复用 UI 映射或改变其他 Unity 端口。
- dist/ 为构建产物，源码与文档仅维护真实模板和清单。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 包清单 | `manifest.json` | 版本定位、Unity/PAD 依赖、设备和包路径 |
| 使用说明 | `README.md` | 部署、资源和兼容性说明 |
| 授权 | `LICENSE` | 端口授权声明 |
| 预览图 | `screenshot.png` | 发行包游戏截图 |
| 启动界面 | `love/` | 选项、显示协调和 Unity 6 启动，见子目录 AGENTS.md |
