use rustler::{Env, NewBinary};
use std::sync::atomic::{AtomicBool, Ordering};
use tracing_subscriber::EnvFilter;

/// Initialize tracing once. Controlled by TEMPORALEX_LOG env var.
/// Defaults to info level for temporalex and temporal SDK.
pub fn init_tracing() {
    static INITIALIZED: AtomicBool = AtomicBool::new(false);
    if INITIALIZED.swap(true, Ordering::SeqCst) {
        return;
    }

    let filter = EnvFilter::try_from_env("TEMPORALEX_LOG")
        .unwrap_or_else(|_| EnvFilter::new("info,temporalio=info"));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .try_init()
        .ok();
}

/// Create a BEAM binary from a byte slice.
pub fn make_binary<'a>(env: Env<'a>, data: &[u8]) -> rustler::Term<'a> {
    let mut bin = NewBinary::new(env, data.len());
    bin.as_mut_slice().copy_from_slice(data);
    bin.into()
}
