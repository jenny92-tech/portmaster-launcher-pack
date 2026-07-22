//! App-specific business and transaction building blocks for Port App Manager.
//!
//! Read-only inventory/config logic and the rollback-safe PortMaster installer
//! live here. Downloads and ordinary game-management mutations remain in the
//! launcher helper; no config text is executed as shell code.

pub mod cache;
pub mod context;
pub mod installer;
pub mod inventory;
pub mod operations;
pub mod path;
pub mod plan;
pub mod resolution;
pub mod runtime;

pub use cache::{CacheDomain, CacheGenerations, CacheInvalidation, OperationKind};
pub use context::{
    CapabilityState, ContextCapabilities, ExpectedInstallContract, FrontendContext,
    FrontendMapEntry, FrontendTransform, ManagedRoots, ManagementMode, ResolvedDeviceContext,
};
pub use installer::{
    InstallError, InstallMode, InstallOutcome, InstallRequest, install_portmaster,
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
