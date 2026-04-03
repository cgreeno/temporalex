use rustler::{Atom, Encoder, LocalPid, Resource, ResourceArc};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, RefUnwindSafe};
use temporalio_client::{Connection, ConnectionOptions};
use tracing::{error, info};
use url::Url;

use crate::atoms;
use crate::runtime::RuntimeResource;
use crate::task_guard::TaskGuard;

/// Opaque handle to a Temporal gRPC connection.
/// Holds a reference to RuntimeResource to prevent premature GC.
pub struct ClientResource {
    pub connection: AssertUnwindSafe<Connection>,
    pub runtime_handle: tokio::runtime::Handle,
    pub _runtime: ResourceArc<RuntimeResource>,
}

impl RefUnwindSafe for ClientResource {}

#[rustler::resource_impl]
impl Resource for ClientResource {}

/// Build ConnectionOptions from the provided arguments.
fn build_conn_opts(
    url: &str,
    api_key: &str,
    headers: HashMap<String, String>,
) -> Result<ConnectionOptions, String> {
    let parsed_url = Url::parse(url).map_err(|e| format!("invalid URL: {e}"))?;

    let scheme = parsed_url.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(format!("URL scheme must be http or https, got: {scheme}"));
    }

    let api_key_opt = if api_key.is_empty() {
        None
    } else {
        Some(api_key.to_string())
    };

    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    Ok(ConnectionOptions::new(parsed_url)
        .identity(format!("temporalex@{}", std::process::id()))
        .maybe_api_key(api_key_opt)
        .maybe_headers(headers_opt)
        .build())
}

/// Async NIF — spawns a Tokio task to connect to Temporal.
/// Sends `{:connected, client_resource}` or `{:connect_error, reason}` to `pid`.
#[rustler::nif]
fn connect(
    runtime: ResourceArc<RuntimeResource>,
    url: String,
    api_key: String,
    headers: HashMap<String, String>,
    pid: LocalPid,
) -> Atom {
    let handle = runtime.core.tokio_handle().clone();
    let spawn_handle = handle.clone();

    spawn_handle.spawn(async move {
        let guard = TaskGuard::new(pid, atoms::connect_error());

        let conn_opts = match build_conn_opts(&url, &api_key, headers) {
            Ok(opts) => opts,
            Err(reason) => {
                guard.complete(|env| (atoms::connect_error(), reason).encode(env));
                return;
            }
        };

        match Connection::connect(conn_opts).await {
            Ok(connection) => {
                info!("Connected to Temporal server");
                let client = ResourceArc::new(ClientResource {
                    connection: AssertUnwindSafe(connection),
                    runtime_handle: handle.clone(),
                    _runtime: runtime,
                });
                guard.complete(|env| (atoms::connected(), client).encode(env));
            }
            Err(e) => {
                error!(error = %e, "Failed to connect to Temporal");
                guard.complete(|env| (atoms::connect_error(), format!("{e}")).encode(env));
            }
        }
    });

    atoms::ok()
}
