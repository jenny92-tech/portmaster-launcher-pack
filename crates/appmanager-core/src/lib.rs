//! App-specific business and transaction building blocks for Port App Manager.
//!
//! Inventory/config logic, ordinary file mutations, Runtime repair, and the
//! PortMaster installer live here. The launcher only orchestrates these native
//! operations; no config text is executed as shell code.

mod archive_bundle;
mod archive_names;
pub mod artifact;
pub mod context;
pub mod device;
pub mod installer;
pub mod inventory;
pub mod operations;
pub mod path;
pub mod plan;
pub mod port_zip;
pub mod resolution;
pub mod runtime;
pub mod storage;
pub mod task;

pub use artifact::{
    ArtifactError, CacheRefreshStatus, RuntimeMetadataOutcome, RuntimeMetadataRequest,
    StableCacheOutcome, StableCacheRequest, StableRelease, StableReleaseOutcome,
    StableReleaseRequest, fetch_stable_release, parse_stable_manifest, refresh_runtime_metadata,
    refresh_stable_cache, stable_cache_row_valid, validate_stable_release_route,
};
pub use context::{
    CapabilityState, ContextCapabilities, ExpectedInstallContract, FrontendContext,
    FrontendMapEntry, FrontendTransform, ManagedAppLocation, ManagedRoots, ManagementMode,
    ResolvedDeviceContext,
};
pub use device::{
    DeviceConfigSources, DeviceIdentity, DeviceResolution, DeviceResolutionError,
    DeviceResolutionRequest, resolve_device,
};
pub use installer::{
    InstallError, InstallMode, InstallOutcome, InstallRequest, PORTMASTER_STATE_PRESERVED,
    install_portmaster, recover_portmaster_transactions,
};
pub use inventory::{
    DeadScriptFact, INVENTORY_SCHEMA, ImageFact, Inventory, InventoryEntry, InventoryKind,
    InventoryOptions, PortFact, RuntimeFact, RuntimeHealth, RuntimeInventory, TrashFact,
};
pub use operations::{
    AUTOINSTALL_DIR_NAME, DEFAULT_LAUNCHER_SCRIPT_NAME, FileAction, FileActionKind,
    FileActionResult, FileApplyOutcome, FileApplyRequest, FileOperationError, PROTECTED_DIR_NAMES,
    PROTECTED_SCRIPT_NAMES, SCAN_EXCLUDED_DIR_NAMES, apply_file_actions,
};
pub use path::{ManagedRoot, PathSafetyError};
pub use plan::{InstallPlan, PlanError, ValidatedInstallPlan};
pub use resolution::{
    AppOwnedPaths, ResolutionConversionError, ResolvedContextInput, ResolvedPlatformContext,
};
pub use runtime::{
    RuntimeMetadata, RuntimeMetadataEntry, RuntimeRepairError, RuntimeRepairItem,
    RuntimeRepairOutcome, RuntimeRepairRequest, RuntimeRepairSource, repair_runtimes,
};
pub use task::{CancellationToken, ProgressChannel, TaskProgress};
