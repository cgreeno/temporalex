import Config

# crate/path live on the `use RustlerPrecompiled` options in
# Temporalex.Native (a dependency's config is never evaluated by
# consumers). Only the build mode is configured here, for this repo's own
# force-built NIFs.
config :temporalex, Temporalex.Native, mode: if(config_env() == :prod, do: :release, else: :debug)

# This repo's own dev/test builds only — a dependency's config is never
# evaluated by consumers. A consumer that filters :metadata must list these
# keys itself to see them on Temporalex's warnings.
config :logger, :default_formatter, metadata: [:workflow_id, :run_id, :phase_result]
