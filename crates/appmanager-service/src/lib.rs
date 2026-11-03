// INPUT:  launcher、resolution 与 web 服务模块
// OUTPUT: EmbeddedService 系列类型、ServiceEvent 和 web 模块
// POS:    供 LOVE-lite 嵌入的 APP Manager 原生服务库入口
#![recursion_limit = "256"]

mod launcher;
mod resolution;
pub mod web;

pub use launcher::{
    EmbeddedAction, EmbeddedBootstrap, EmbeddedRequest, EmbeddedService, ServiceEvent,
};
