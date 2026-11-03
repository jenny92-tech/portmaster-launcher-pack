// INPUT:  config/environment/platform/predicate/source/refresh/file/github/health 模块
// OUTPUT: portkit_core 公共模块、配置解析和系统基础接口重导出
// POS:    设备配置、下载与文件基础设施的可复用 Rust 核心库入口
pub mod config;
pub mod environment;
pub mod error;
pub mod file;
pub mod github;
pub mod health;
pub mod platform;
pub mod predicate;
pub mod refresh;
pub mod source;

pub use config::{
    Config, ConfigLoader, FragmentSource, LocalFragmentSource, PlatformEntry, RootConfig,
    SupportedContract,
};
pub use environment::{CommandEnvironment, EnvironmentOperation, EnvironmentPolicy};
pub use error::{Error, Result};
pub use file::{
    DigestAlgorithm, ExclusiveFileLock, atomic_copy, atomic_write, digest_file, zip_readable,
};
pub use health::{HealthCheck, HealthReport, HealthStatus, evaluate_health};
pub use platform::{
    BundleFormat, DetectionContext, Location, LocationKind, LocationRole, Resolution,
    ResolvedLocation, required_location_format, required_location_roles,
};
pub use refresh::{ConfigRefreshRequest, ConfigRefreshStatus, refresh_config};
pub use source::{
    CandidateSelector, ConfigCandidate, ConfigOrigin, ResolvedSelection, SelectedConfig,
};
