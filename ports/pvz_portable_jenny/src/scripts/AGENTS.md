# PvZ 打包入口

`_kit/dist_port.sh pvz_portable_jenny` 调用本目录的构建脚本。提供 PVZ_PORTABLE_RUNTIME 时，仅收集 pvz_portable.aarch64、libs.aarch64、gconv、licenses；省略时生成无运行时的启动层，游戏资源始终不收集。

## 约束

- 运行时目录和目录内成员不得为符号链接；输入与端口发行输出分离。
- main.pak、properties、userdata、注册信息和玩家设置不属于运行时白名单。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 构建 | `dist-port.sh` | 拒绝链接输入，组装固定运行时清单并记录负载身份 |
