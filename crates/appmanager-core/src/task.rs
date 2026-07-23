use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::Serialize;

/// Process-local cancellation shared by the embedded UI and worker threads.
/// Diagnostic CLI adapters may additionally use their legacy marker file.
#[derive(Clone, Debug, Default)]
pub struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    pub fn reset(&self) {
        self.0.store(false, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub struct TaskProgress {
    pub phase: String,
    pub runtime: String,
    pub index: u64,
    pub count: u64,
    pub current: u64,
    pub total: u64,
    pub speed: u64,
    pub detail: String,
}

/// Latest-value process-local progress channel. Progress is intentionally
/// coalesced because the UI only needs the newest frame, not an unbounded log.
#[derive(Clone, Debug, Default)]
pub struct ProgressChannel(Arc<Mutex<Option<TaskProgress>>>);

impl ProgressChannel {
    pub fn publish(&self, progress: TaskProgress) {
        *self.0.lock().unwrap_or_else(|value| value.into_inner()) = Some(progress);
    }

    pub fn take(&self) -> Option<TaskProgress> {
        self.0
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .take()
    }

    pub fn clear(&self) {
        self.0
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clones_observe_the_same_process_local_state() {
        let first = CancellationToken::default();
        let second = first.clone();
        second.cancel();
        assert!(first.is_cancelled());
        first.reset();
        assert!(!second.is_cancelled());
    }

    #[test]
    fn progress_is_coalesced_to_the_latest_value() {
        let channel = ProgressChannel::default();
        channel.publish(TaskProgress {
            current: 1,
            ..TaskProgress::default()
        });
        channel.publish(TaskProgress {
            current: 2,
            ..TaskProgress::default()
        });
        assert_eq!(channel.take().unwrap().current, 2);
        assert!(channel.take().is_none());
    }
}
