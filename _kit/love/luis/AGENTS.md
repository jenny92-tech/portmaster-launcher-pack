# 供 Kit 适配的 LUIS 控件子集

共享 `ui_components.lua` 为本目录控件注入主题与物理尺寸，控件只负责绘制和激活。页面组织、焦点、滚动及输入语义由 Kit 持有，导入范围限于按钮、复选框、开关及直接依赖。

## 约束

- `upstream.json` 固定来源提交和导入前 SHA256，README 解释本地差异；构建不联网更新。
- LUIS 附加条款与 flux 独立 MIT 许可随组件一起收集，保留原文。
- 不引入上游全局手柄轮询、布局缩放、默认字体或模块目录扫描。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 控件 | `widgets/` | 按钮、复选框和开关对象、绘制与激活 |
| 直接依赖 | `3rdparty/` | 几何、装饰器、命中检测和 tween |
| 来源清单 | `upstream.json` | 固定提交及导入前 SHA256 |
| 适配说明 | `README.md` | 导入范围和可审阅的本地修改 |
| LUIS 许可 | `LICENSE` | MIT License with Additional Terms 原文 |
| flux 许可 | `LICENSE-flux.txt` | rxi 的 MIT 许可原文 |
