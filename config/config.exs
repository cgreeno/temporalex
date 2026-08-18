import Config

# crate/path live on the `use RustlerPrecompiled` options in
# Temporalex.Native (a dependency's config is never evaluated by
# consumers). Only the build mode is configured here, for this repo's own
# force-built NIFs.
config :temporalex, Temporalex.Native, mode: if(config_env() == :prod, do: :release, else: :debug)
