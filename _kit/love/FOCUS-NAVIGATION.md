# 方向键焦点导航 UX 参考

共享 UI 的方向导航设计依据。组件现行行为以 README 和回归测试为准。

## 官方依据

| 主题 | 结论与来源 |
|---|---|
| 容器内优先 | Compose `focusGroup()` 让分组作为导航整体，焦点仍落在子元素；组内未完全可见项目也可优先于组外更近目标。它不是让每个视觉容器都永久锁住焦点。[Android Compose](https://developer.android.com/develop/ui/compose/touch-input/focus/change-focus-behavior) |
| 上下保持对齐 | Microsoft XYFocus 的 `Projection` 从当前矩形沿方向投射，寻找遇到的首个元素；另提供方向轴距离和曼哈顿距离策略。因此上下移动不必等同于“谁的 y 最近就去谁”。[XYFocusNavigationStrategy](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.input.xyfocusnavigationstrategy?view=windows-app-sdk-2.0) |
| 边界向外查找 | W3C 空间导航先查当前逻辑分组，无候选时尝试该方向滚动；不能再滚动才递归向祖先容器查找。此处是搜索范围逐级扩大，不是普通键盘事件冒泡。[CSS Spatial Navigation §3、§8](https://www.w3.org/TR/css-nav-1/) |
| 展示项与可操作项 | Compose 将可聚焦能力单独控制，可用 `canFocus=false` 排除目标；不可聚焦不自动禁止点击。故“展示、禁用、可聚焦、可激活”应分别表达，而非从外观推断。[Android Compose](https://developer.android.com/develop/ui/compose/touch-input/focus/change-focus-behavior) |
| 滚动 | Android TV 要求带焦点的滚动列表可通过上下键继续滚动并选择项目；W3C 还区分先滚动发现目标与直接聚焦屏外目标的策略。[Android TV](https://developer.android.com/training/tv/get-started/navigation)、[CSS Spatial Navigation §9.2](https://www.w3.org/TR/css-nav-1/#scrolling) |
| 恢复 | Compose `focusRestorer` 在离组时保存最后焦点，重入时恢复；原项目已不可聚焦时使用 fallback。[focusRestorer](https://developer.android.com/reference/kotlin/androidx/compose/ui/focus/focusRestorer.modifier) |

注意：CSS Spatial Navigation Level 1 是工作草案，适合作为算法模型参考，不能宣称为普遍已实现的浏览器标准。Android TV 文档对显式导航连接还建议闭环；所以“禁止全局循环”不是各平台一致规定，而应是本项目为保持空间方向直觉作出的明确选择。

## 项目建议（基于以上依据的设计判断）

1. 四向统一采用“当前导航容器 → 方向合法候选 → 对齐优先 → 距离决胜”，而非只修左右。上下优先水平投影重叠的目标；左右对称地优先垂直投影重叠。没有对齐候选时才允许合理斜向回退。
2. 行、列表、侧栏等按真实导航职责分组，不按所有绘制层盲目分组。同组该方向无候选且不能继续滚动，再向父级找相邻组；用退出位置选择进入目标，避免每次回到首项。
3. 组内滚动优先于跳到页脚或侧栏；新焦点进入后确保可见。屏外项目不等于隐藏或禁用项目，不应直接丢弃。
4. 普通说明、标题、状态文字不占方向焦点；禁用动作默认跳过。若确需聚焦解释禁用原因，作为明确例外，保持不能激活并提供解释；这不是引用文档规定的统一禁用规则。
5. 返回页面、关闭弹窗恢复先前稳定目标；目标消失则退到同组合理候选，再退到页面默认目标。普通跨行移动保留几何对齐，不能让历史恢复覆盖用户刚输入的空间方向。
6. 根边界无候选时保持原焦点，不做全页面首尾循环；明确设计的轮播可局部例外。应检查每个可操作控件仍有可达路径，避免容器边界形成陷阱。

## 应用与验证

当前组件契约见 [共享 UI](README.md)，自动回归见
[自适应布局测试](../../tests/test_app_adaptive_layout.py)。本研究保留设计依据，
不以旧代码行号或一次审查推断维护当前缺陷清单。

验收场景：上下同列优先、无同列时合理回退、组内滚动到尾才退出、纯展示/禁用项跳过、跨组进入位置、弹窗返回恢复、目标删除回退、根边界无循环。
