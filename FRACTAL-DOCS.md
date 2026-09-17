# 分形文档协议（Fractal Documentation Protocol）

> 本项目采用分形文档协议；所有 AI Agent 和开发者按本文件导航和维护文档。

## 如何阅读本项目

按需逐层展开，不要一次性加载所有文件：

1. 根 `AGENTS.md`：项目边界、已有仓库约束和顶层业务域清单。
2. 目录级 `AGENTS.md`：当前模块的地位、逻辑、约束及文件/子目录分工。
3. 源码的 `INPUT` / `OUTPUT` / `POS` 三行头注释：文件直接依赖、公开输出和定位。

项目现有的发布前版本纪律仍然有效；文档初始化与源码注释变化不授权版本升级。

## 管理范围

- 覆盖仓库维护的 Rust、Shell（含 `*.sh.template` 与 `handheld-lab/devtools`）、Python、Lua、C、C#（含 `*.csx`）、GDScript、Godot shader 及 HTML 源码。
- `crates/love-lite/vendor/` 是随仓库维护的定制源码输入，纳入导航与头注释；保留上游许可证及原有说明。
- 配置、Schema、清单、锁文件、文档、字体、图片及二进制不添加源码头注释；在所属业务域清单中说明用途。
- 排除 `target/`、`dist/`、`build/`、`node_modules/`、隐藏工作目录及其他被忽略的构建/实验产物。
- 生成文件不手工维护头注释。`tools/record_screen.sh` 由 `_kit/build_recorder_tool.sh` 从 `_kit/recorder.sh` 生成，`ports/recorder/portable/bin/record_screen.sh` 是发行副本；按生成器维护。
- 标记为生成模板快照的 STS2 POC 脚本按其目录 `AGENTS.md` 的边界处理；维护模板及手写实验脚本，生成快照只登记用途。
- 不读取或改写本地凭据；不因初始化文档执行部署、设备探测、游戏资源修改或二进制重建。

## 第一层：源码三行头注释

三行顺序固定。`INPUT:` 后两个空格，`OUTPUT:` 后一个空格，`POS:` 后四个空格，使内容对齐。
`INPUT` 只列直接依赖，`OUTPUT` 只列公开接口或脚本产物，`POS` 用一句话描述具体定位。
下面仅列项目实际存在的语言；例子用于格式说明，不代替源码本身的接口定义。

### Rust（`*.rs`）

放在 crate attributes、原有描述性注释和 `use` 之前；保留 `//!` 文档与条件编译标记。

```rust
// INPUT:  serde, serde_json；设备配置与文件系统
// OUTPUT: 对外导出的配置加载与校验接口
// POS:    PortKit 配置契约的原生加载边界
```

### Shell（`*.sh`、`*.bash`、`*.sh.template`、无扩展名入口）

shebang 必须仍是第一行，三行注释放在其后、原有许可证和执行语句之前。

```bash
#!/usr/bin/env bash
# INPUT:  启动脚本目录与 PortMaster 安装位置
# OUTPUT: portmaster_discover()；全局 controlfolder
# POS:    为启动器定位 PortMaster 控制目录
```

### Python（`*.py`）

有 shebang 时放在其后，无 shebang 时放在第一行；保留有效的编码声明，位于 docstring、future import 和普通 import 之前。

```python
#!/usr/bin/env python3
# INPUT:  json, pathlib；人工维护的配置片段
# OUTPUT: 配置生成命令与生成内容一致性检查
# POS:    将配置源片段合成为分发契约
```

### Lua（`*.lua`）

```lua
-- INPUT:  kit 与端口字段/页面声明
-- OUTPUT: launcher.define() 及字段构造接口
-- POS:    从端口声明生成共享设置 UI 与启动配置
```

### C（`*.c`）

放在原有说明、预处理指令及 `#include` 之前，不改变宏定义和平台保护条件。

```c
// INPUT:  Linux 输入设备接口与命令行参数
// OUTPUT: 掌机输入辅助程序命令行入口
// POS:    为设备实验提供原生输入事件工具
```

### C#（`*.cs`、`*.csx`）

使用 `//`，放在 `using`、`#r` 和命名空间之前；`.csx` 的 dotnet-script shebang 保持第一行。

```csharp
// INPUT:  Godot、Harmony 与游戏程序集
// OUTPUT: 移植补丁注册入口
// POS:    为掌机运行时应用游戏兼容补丁
```

### GDScript（`*.gd`）

使用 `#`，放在 `@tool`、`extends`、`class_name` 和成员声明之前。

```gdscript
# INPUT:  Godot 节点生命周期
# OUTPUT: 保留插件挂载点的兼容脚本
# POS:    为移植资源包提供可替换的插件占位实现
```

### Godot shader（`*.gdshader`）

使用 `//`，放在 `shader_type` 与 `render_mode` 之前。

```glsl
// INPUT:  屏幕纹理与效果参数
// OUTPUT: canvas_item 片元颜色
// POS:    提供适配移动图形后端的画面效果
```

### HTML（内嵌 CSS / JavaScript）

保留 `<!DOCTYPE html>` 为首行，在其后用三行 HTML 注释描述整个页面；内嵌样式和脚本不另建文件头。

```html
<!DOCTYPE html>
<!-- INPUT:  浏览器 DOM、fetch 与 App Manager Web API -->
<!-- OUTPUT: 管理状态和操作的浏览器交互页面 -->
<!-- POS:    为管理服务提供内嵌 Web 操作入口 -->
```

已有描述性注释、许可证、shebang、编码声明与语言指令均应保留。初始化只增加注释，不改动执行逻辑。

## 第二层：目录级 AGENTS.md

每个源码目录以及连接源码子树的中间目录放一个 `AGENTS.md`，自底向上建立，再由父目录登记子目录。
纯资源目录不强制单独创建文档；由最近的父目录清单解释。

```markdown
# 模块名

> 一句话定位。

## 地位

在上级模块中的角色。

## 逻辑

内部数据流与调用关系。

## 约束

- 模块的真实技术边界。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 模块入口 | `main.rs` | 对外入口职责 |
```

清单使用相对当前目录的真实直接文件/子目录，一项一行；`AGENTS.md` 自身无需自引用。
不登记已删除文件或生成目录中的临时内容。根 `AGENTS.md` 保留用户原有约束，只合并项目导航与本协议引用，不复制协议正文。
用户自定义 `CLAUDE.md` 不属于协议维护范围，保持原样；仅有 `AGENTS.md` 引用或软链接的冗余文件才可清理。

## 第三层：级联更新规则

| 触发事件 | 文件级 | 所属目录级 | 上级目录级 |
|----------|--------|------------|------------|
| 新增源码 | 添加三行注释 | 更新文件清单 | 检查导航链，新子树或职责变化时更新 |
| 删除源码 | — | 移除对应条目 | 检查导航链，移除失效子树引用 |
| 修改接口/职责 | 更新三行注释 | 更新职责描述 | 影响上级职责时更新 |
| 仅改内部实现 | 检查注释准确性 | 不更新 | 不更新 |

修改后检查头注释、目录清单与父子引用一致性，避免幽灵条目、遗漏条目及级联断链。
源码内容散列会包含注释和位于源码树内的文档；若因此触发预置二进制过期校验，应通过原有构建流程重建，不能只改 revision 文件宣称二进制已匹配。

可使用维护技能：

- `/fractal-docs update`：根据变更维护相应层级。
- `/fractal-docs check`：检查完整性；职责不清楚时先读代码，再向用户确认。

`fractal-context` 若已安装，可只读浏览文档；它不创建或修复文档。
