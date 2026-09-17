# INPUT:  Godot Node 基类
# OUTPUT: 无操作的 Sentry 自加载替代节点
# POS:    为缺少 ARM64 Sentry 扩展的运行时保留有效脚本引用
extends Node
# StS2 patch: original autoload init script referenced SentrySDK/SentryEvent
# classes from the sentry GDExtension, which has no linux.arm64 prebuilt.
# Replaced with a no-op Node so any leftover res:// reference still resolves.
