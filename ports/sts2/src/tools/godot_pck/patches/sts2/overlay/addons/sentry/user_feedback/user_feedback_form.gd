# INPUT:  Godot Control 基类
# OUTPUT: 无操作的用户反馈表单替代控件
# POS:    避免场景加载引用 ARM64 不存在的 Sentry SDK 类型
extends Control
# StS2 patch: original referenced SentrySDK / SentryEvent, neither of
# which exists at runtime on arm64. Replaced with an empty Control so the
# scene tree still loads.
