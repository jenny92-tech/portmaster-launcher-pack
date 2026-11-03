# LUIS 组件子集

固定上游源码只提供 Kit 使用的按钮、复选框、开关及直接依赖。`../ui_components.lua` 注入上下文和主题，Kit 拥有页面、焦点、滚动和语义输入。

## 约束

- 来源与原始文件 SHA256 记录在 upstream.json；本地差异见 README，不随构建联网更新。
- 保留 LUIS 的完整附加条款与 flux 独立 MIT 许可；发行时与组件一起收集。
- 不引入上游全局控制器轮询、布局缩放、默认字体或模块目录扫描。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 控件 | `widgets/` | 按钮、复选框和开关对象、绘制与激活 |
| 直接依赖 | `3rdparty/` | 几何、装饰器、命中检测和 tween |
| 来源清单 | `upstream.json` | 固定提交及导入前 SHA256 |
| 适配说明 | `README.md` | 导入范围和可审阅的本地修改 |
| LUIS 许可 | `LICENSE` | MIT License with Additional Terms 原文 |
| flux 许可 | `LICENSE-flux.txt` | rxi 的 MIT 许可原文 |
