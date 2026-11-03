# CPU 光栅化实现

`lib.rs` 向相邻 API 层暴露 PixelBuffer。缓冲管理 RGBA 和 stencil 数据，图元、图像采样、混合及点阵文字直接写入像素，最终由 LOVE-lite 宿主呈现。

## 约束

- 源码来源见 `../../../UPSTREAM.md`，保留原有说明并作为真实构建输入维护。
- 实现保持纯 Rust 标准库边界，不加入 Sixel/Ratatui 等终端呈现能力。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 模块入口 | `lib.rs` | 暴露 pixel_buffer 模块 |
| CPU 光栅化 | `pixel_buffer.rs` | 像素缓冲、混合、图元、图像变换、效果与点阵文字 |
