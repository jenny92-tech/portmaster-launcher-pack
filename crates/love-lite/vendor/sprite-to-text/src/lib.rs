// INPUT:  pixel_buffer 软件渲染模块
// OUTPUT: pixel_buffer 公共模块
// POS:    上游衍生的纯 CPU 像素缓冲依赖入口，不包含终端渲染器
// Preserve imported upstream code as-is; local adapter code is linted strictly.
#![allow(clippy::all)]

pub mod pixel_buffer;
