use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::context::CapabilityState;

pub const CACHE_SCHEMA: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CacheDomain {
    Ports,
    Trash,
    RequiredRuntimes,
    InstalledRuntimes,
    RuntimeMetadata,
    Sizes,
}

impl CacheDomain {
    pub const ALL: [Self; 6] = [
        Self::Ports,
        Self::Trash,
        Self::RequiredRuntimes,
        Self::InstalledRuntimes,
        Self::RuntimeMetadata,
        Self::Sizes,
    ];
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OperationKind {
    InstallPortmaster,
    InstallRuntime,
    Trash,
    DeleteManaged,
    RestoreTrash,
    RestoreItem,
    EmptyTrash,
    DeleteItem,
    CleanAppleDouble,
    AcknowledgeDeviceRisk,
    AcknowledgeDeviceSupport,
    Unknown(String),
}

impl OperationKind {
    pub fn parse(value: &str) -> Self {
        match value {
            "INSTALL_PORTMASTER" => Self::InstallPortmaster,
            "INSTALL_RUNTIME" => Self::InstallRuntime,
            "TRASH" => Self::Trash,
            "DELETE_MANAGED" => Self::DeleteManaged,
            "RESTORE_TRASH" => Self::RestoreTrash,
            "RESTORE_ITEM" => Self::RestoreItem,
            "EMPTY_TRASH" => Self::EmptyTrash,
            "DELETE_ITEM" => Self::DeleteItem,
            "CLEAN_APPLEDOUBLE" => Self::CleanAppleDouble,
            "ACK_DEVICE_RISK" => Self::AcknowledgeDeviceRisk,
            "ACK_DEVICE_SUPPORT" => Self::AcknowledgeDeviceSupport,
            other => Self::Unknown(other.to_owned()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CacheGenerations {
    pub schema: u32,
    pub global: u64,
    pub domains: BTreeMap<CacheDomain, u64>,
}

impl Default for CacheGenerations {
    fn default() -> Self {
        Self {
            schema: CACHE_SCHEMA,
            global: 0,
            domains: CacheDomain::ALL
                .into_iter()
                .map(|domain| (domain, 0))
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CacheInvalidation {
    pub invalidate_all: bool,
    pub domains: BTreeSet<CacheDomain>,
    pub previous: CacheGenerations,
    pub next: CacheGenerations,
    pub reasons: Vec<String>,
}

#[derive(Debug, Error)]
pub enum CacheStateError {
    #[error("unsupported cache schema {actual}; expected {expected}")]
    Schema { actual: u32, expected: u32 },
    #[error("cache state is missing generation for domain {0:?}")]
    MissingDomain(CacheDomain),
}

impl CacheGenerations {
    pub fn validate(&self) -> Result<(), CacheStateError> {
        if self.schema != CACHE_SCHEMA {
            return Err(CacheStateError::Schema {
                actual: self.schema,
                expected: CACHE_SCHEMA,
            });
        }
        for domain in CacheDomain::ALL {
            if !self.domains.contains_key(&domain) {
                return Err(CacheStateError::MissingDomain(domain));
            }
        }
        Ok(())
    }

    pub fn invalidate(
        &self,
        capability: CapabilityState,
        operations: &[OperationKind],
    ) -> CacheInvalidation {
        let previous = self.clone();
        let mut domains = BTreeSet::new();
        let mut all = capability == CapabilityState::Unknown;
        let mut reasons = Vec::new();
        if all {
            reasons.push("unknown-cache-capability".to_owned());
        }

        for operation in operations {
            match operation {
                OperationKind::InstallPortmaster => {
                    all = true;
                    reasons.push("install-portmaster".to_owned());
                }
                OperationKind::InstallRuntime => {
                    domains.extend([
                        CacheDomain::RequiredRuntimes,
                        CacheDomain::InstalledRuntimes,
                        CacheDomain::RuntimeMetadata,
                    ]);
                }
                OperationKind::Trash
                | OperationKind::DeleteManaged
                | OperationKind::RestoreTrash
                | OperationKind::RestoreItem => {
                    domains.extend([
                        CacheDomain::Ports,
                        CacheDomain::Trash,
                        CacheDomain::RequiredRuntimes,
                        CacheDomain::InstalledRuntimes,
                        CacheDomain::RuntimeMetadata,
                        CacheDomain::Sizes,
                    ]);
                }
                OperationKind::EmptyTrash | OperationKind::DeleteItem => {
                    domains.extend([CacheDomain::Trash, CacheDomain::Sizes]);
                }
                OperationKind::CleanAppleDouble => {
                    domains.extend([CacheDomain::Ports, CacheDomain::Sizes]);
                }
                OperationKind::AcknowledgeDeviceRisk | OperationKind::AcknowledgeDeviceSupport => {}
                OperationKind::Unknown(name) => {
                    all = true;
                    reasons.push(format!("unknown-operation:{name}"));
                }
            }
        }
        if all {
            domains = CacheDomain::ALL.into_iter().collect();
        }

        let mut next = previous.clone();
        if !domains.is_empty() {
            next.global = next.global.saturating_add(1);
            for domain in &domains {
                let generation = next.domains.entry(*domain).or_insert(0);
                *generation = generation.saturating_add(1);
            }
        }
        CacheInvalidation {
            invalidate_all: all,
            domains,
            previous,
            next,
            reasons,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_capability_invalidates_only_known_dependencies() {
        let result = CacheGenerations::default()
            .invalidate(CapabilityState::Current, &[OperationKind::InstallRuntime]);
        assert!(!result.invalidate_all);
        assert_eq!(result.next.global, 1);
        assert_eq!(result.next.domains[&CacheDomain::Ports], 0);
        assert_eq!(result.next.domains[&CacheDomain::RequiredRuntimes], 1);
    }

    #[test]
    fn unknown_capability_or_operation_fails_safe_to_full_invalidation() {
        let unknown_capability = CacheGenerations::default()
            .invalidate(CapabilityState::Unknown, &[OperationKind::DeleteItem]);
        assert!(unknown_capability.invalidate_all);
        assert_eq!(unknown_capability.domains.len(), CacheDomain::ALL.len());

        let unknown_operation = CacheGenerations::default().invalidate(
            CapabilityState::Current,
            &[OperationKind::Unknown("FUTURE_OP".to_owned())],
        );
        assert!(unknown_operation.invalidate_all);
    }

    #[test]
    fn rejects_unknown_or_incomplete_cache_schemas() {
        let future = CacheGenerations {
            schema: 2,
            ..CacheGenerations::default()
        };
        assert!(matches!(
            future.validate(),
            Err(CacheStateError::Schema { .. })
        ));

        let mut incomplete = CacheGenerations::default();
        incomplete.domains.remove(&CacheDomain::Ports);
        assert!(matches!(
            incomplete.validate(),
            Err(CacheStateError::MissingDomain(CacheDomain::Ports))
        ));
    }
}
