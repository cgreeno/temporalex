import Config

config :temporalex, Temporalex.Native,
  crate: :temporalex_nif,
  path: "native/temporalex_nif",
  mode: if(config_env() == :prod, do: :release, else: :debug)
