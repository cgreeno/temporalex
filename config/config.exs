import Config

# crate/path live on the `use RustlerPrecompiled` options in
# Temporalex.Native (a dependency's config is never evaluated by
# consumers). Only the build mode is configured here, for this repo's own
# force-built NIFs.
config :temporalex, Temporalex.Native, mode: if(config_env() == :prod, do: :release, else: :debug)

# Declared so the keys survive a consumer's :metadata filter, and so Credo's
# Logger metadata check can see them.
config :logger, :default_formatter, metadata: [:workflow_id, :run_id, :phase_result]
