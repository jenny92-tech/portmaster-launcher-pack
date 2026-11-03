# Fluent 功能图标

微软 Fluent System Icons 的官方 filled SVG 子集及离线渲染产物，由共享 `ui_icons.lua` 按当前文字颜色绘制。来源和 SHA-256 固定在 `upstream.json`，不依赖联网或图标字体。

## 约束

- `svg/` 保留上游原文件；项目不手绘或修改图形路径。
- `atlas.png`、`layout.lua` 由 `_kit/build_ui_icons.cjs` 使用 Sharp 离线生成，不手工改写。环境安装 Sharp 后运行 `node _kit/build_ui_icons.cjs`。
- 每个图标预渲染 8–48 物理像素的整数尺寸，运行时选择对应单元，不缩放纹理，保留小屏抗锯齿边缘。
- `_kit/stage_love_ui.sh` 只分发 atlas、布局、来源和许可证，不分发 SVG 源或文档。增加图标时同步来源清单并重建；不改变格式版本。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 上游原图 | `svg/` | 固定 revision 的 14 个官方 filled SVG，含设置页语言图标 |
| 物理像素图集 | `atlas.png` | 白色透明图标，由绘制颜色统一着色 |
| 图集布局 | `layout.lua` | 生成的尺寸、行索引与纹理坐标约定 |
| 来源清单 | `upstream.json` | 官方仓库、revision、图标路径和摘要、渲染参数 |
| 许可 | `LICENSE` | 随运行负载保留的微软 MIT 许可 |
