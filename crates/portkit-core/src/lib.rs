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
pub use file::{DigestAlgorithm, ExclusiveFileLock, atomic_write, digest_file, zip_readable};
pub use health::{HealthCheck, HealthReport, HealthStatus, evaluate_health};
pub use platform::{DetectionContext, Resolution};
pub use refresh::{ConfigRefreshRequest, ConfigRefreshStatus, refresh_config};
pub use source::{
    CandidateSelector, ConfigCandidate, ConfigOrigin, ResolvedSelection, SelectedConfig,
};
