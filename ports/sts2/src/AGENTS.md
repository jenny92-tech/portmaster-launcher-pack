# STS2 兼容源码与构建输入

> 组织托管补丁、移动着色器、运行时资料和移植工具。

## 地位

STS2 端口中与 LÖVE 前端分离的兼容实现和打包后端。

## 逻辑

scripts 组合 STS2LinuxLauncher、shaders 和运行时输入；tools 为游戏文件转换及设备调试提供独立入口。

## 约束

- 游戏原版程序集和资源由玩家提供，不在源码树或发布包中分发。
- external 为构建产物获取说明/占位，runtime 中已有二进制不因文档修改重建。
- 本仓库未首发，遵循根 AGENTS 的版本纪律，不自行升级格式或包版本。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| STS2LinuxLauncher | `STS2LinuxLauncher/` | Godot 注入入口与 Harmony 运行时兼容补丁 |
| docs | `docs/` | 开发笔记、实验与故障记录的文档入口 |
| external | `external/` | Godot/FMOD/Spine 外部构建产物获取说明 |
| linux | `linux/` | 玩家游戏数据准备说明与 .NET 运行时配置模板 |
| runtime | `runtime/` | 随端口提供的 KMSDRM SDL2 二进制和版本记录 |
| scripts | `scripts/` | 核心 dist、发布运行时组装与设备部署 |
| shaders | `shaders/` | Mali 友好的 Godot 替代着色器 |
| tools | `tools/` | 程序集、PCK、Steam 桩与设备诊断工具 |

