# Wine 构建与分发

构建器按层输出独立产物：dist-port 组装运行器，build-runtime 从已校验源码构建公共组件，dist-game 只封装游戏声明，准备工具另行发行。dist-zip 将运行器映射到 SD 布局；这些入口均不扫描玩家游戏目录或读取设备。

## 约束

- 只复制明确白名单；禁止打包用过的映像、游戏副本、玩家 prefix 和日志。
- 游戏 ZIP 拥有独立目录，不能把共享应用作为卸载项。
- 不生成未经发布的远程 URL；离线包与 HTTPS 发布地址分开处理。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 运行器组装 | `dist-port.sh` | 运行器代码/定义暂存及构建身份 |
| SD 卡布局封装 | `dist-zip.py` | roms/windows/.winecellar 布局与 Ports 桥接 |
| 私有启动环境 | `build-bootstrap.py` | 构建解释器、字体和输入工具只读映像 |
| 入门包组合 | `dist-starter.py` | 运行器/组件/适配组合，不含游戏资源 |
| 原生界面预览 | `preview-menu.py` | 内存夹具上的离屏 SDL 多尺寸 PNG |
| 运行组件构建 | `build-runtime.py` | 来源校验、干净源码构建及组件离线 ZIP |
| 游戏分发 | `dist-game.py` | 独立游戏目录、bottle 和 gptk，无游戏 data |
| 准备工具分发 | `dist-prepare-tools.py` | 电脑准备工具和对应源码/许可 |
