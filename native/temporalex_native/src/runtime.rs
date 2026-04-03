use rustler::{Resource, ResourceArc};
use std::panic::{AssertUnwindSafe, RefUnwindSafe};
use temporalio_sdk_core::{CoreRuntime, RuntimeOptions, TokioRuntimeBuilder};
use tracing::info;

use crate::helpers;

/// Opaque handle to the Temporal Core SDK runtime + Tokio runtime.
/// Singleton per BEAM node — created once by Temporalex.Runtime GenServer.
pub struct RuntimeResource {
    pub core: AssertUnwindSafe<CoreRuntime>,
}

// CoreRuntime contains Tokio internals that aren't RefUnwindSafe.
// Safe because we never unwind across NIF boundaries.
impl RefUnwindSafe for RuntimeResource {}

#[rustler::resource_impl]
impl Resource for RuntimeResource {}

/// Synchronous NIF — creates the CoreRuntime with a Tokio multi-thread runtime.
/// Called once at application startup.
#[rustler::nif(schedule = "DirtyCpu")]
fn create_runtime() -> Result<ResourceArc<RuntimeResource>, String> {
    helpers::init_tracing();

    let runtime_opts = RuntimeOptions::builder()
        .build()
        .map_err(|e| format!("runtime options: {e}"))?;

    let tokio_builder = TokioRuntimeBuilder::default();

    let core = CoreRuntime::new(runtime_opts, tokio_builder)
        .map_err(|e| format!("create runtime: {e}"))?;

    info!("Temporal CoreRuntime created");

    Ok(ResourceArc::new(RuntimeResource {
        core: AssertUnwindSafe(core),
    }))
}
