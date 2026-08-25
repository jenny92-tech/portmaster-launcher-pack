#![recursion_limit = "256"]

mod launcher;
mod resolution;
pub mod web;

pub use launcher::{
    EmbeddedAction, EmbeddedBootstrap, EmbeddedRequest, EmbeddedService, ServiceEvent,
};
