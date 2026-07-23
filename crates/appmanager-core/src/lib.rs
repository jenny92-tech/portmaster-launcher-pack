//! App-specific business and transaction building blocks for Port App Manager.
//!
//! Inventory/config logic, ordinary file mutations, Runtime repair, and the
//! rollback-safe PortMaster installer live here. The launcher only orchestrates
//! these native operations; no config text is executed as shell code.

pub mod artifact;
pub mod cache;
pub mod context;
pub mod device;
pub mod installer;
pub mod inventory;
pub mod operations;
pub mod path;
pub mod plan;
pub mod resolution;
pub mod runtime;
pub mod task;

pub use artifact::{
    ArtifactError, CacheRefreshStatus, RuntimeMetadataOutcome, RuntimeMetadataRequest,
    StableCacheOutcome, StableCacheRequest, StableRelease, StableReleaseOutcome,
    StableReleaseRequest, fetch_stable_release, parse_stable_manifest, refresh_runtime_metadata,
    refresh_stable_cache, stable_cache_row_valid, validate_stable_release_route,
};
pub use cache::{CacheDomain, CacheGenerations, CacheInvalidation, OperationKind};
pub use context::{
    CapabilityState, ContextCapabilities, ExpectedInstallContract, FrontendContext,
    FrontendMapEntry, FrontendTransform, ManagedRoots, ManagementMode, ResolvedDeviceContext,
};
pub use device::{
    DeviceConfigSources, DeviceIdentity, DeviceResolution, DeviceResolutionError,
    DeviceResolutionRequest, resolve_device,
};
pub use installer::{
    InstallError, InstallMode, InstallOutcome, InstallRequest, PendingValidationError,
    PendingValidationOutcome, PendingValidationRequest, PendingValidationStatus,
    install_portmaster, validate_pending_install,
};
pub use inventory::{
    DeadScriptFact, ImageFact, Inventory, InventoryEntry, InventoryKind, InventoryOptions,
    PortFact, RuntimeFact, RuntimeHealth, RuntimeInventory, TrashFact,
};
pub use operations::{
    FileAction, FileActionKind, FileApplyOutcome, FileApplyRequest, FileOperationError,
    SizeScanOutcome, SizeScanRequest, apply_file_plan, plan_contains_only_file_actions,
    scan_size_cache,
};
pub use path::{ManagedRoot, PathSafetyError};
pub use plan::{InstallPlan, PlanError, REQUIRED_PRESERVED_CORE_DIRS, ValidatedInstallPlan};
pub use resolution::{
    AppOwnedPaths, ResolutionConversionError, ResolvedContextInput, ResolvedPlatformContext,
};
pub use runtime::{
    RuntimeMetadata, RuntimeMetadataEntry, RuntimeRepairError, RuntimeRepairItem,
    RuntimeRepairOutcome, RuntimeRepairRequest, RuntimeRepairSource, repair_runtimes,
};
pub use task::{CancellationToken, ProgressChannel, TaskProgress};
