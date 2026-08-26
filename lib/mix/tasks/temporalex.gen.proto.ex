defmodule Mix.Tasks.Temporalex.Gen.Proto do
  @shortdoc "Regenerates priv/proto/temporal_core.binpb from the pinned sdk-rust revision"

  @moduledoc """
  Regenerates the Temporal Core descriptor the Elixir decoder reads.

      mix temporalex.gen.proto

  The revision is taken from `native/temporalex_nif/Cargo.lock`, never from an
  argument, so the descriptor cannot be generated against a tree the NIF is not
  built against. The proto sources come from Cargo's own checkout of that
  revision; run `mix compile` first if it is absent, or pass `--src` to point at
  a sibling sdk-rust clone.

  `mix test test/temporalex/proto_descriptor_test.exs` fails when the committed
  descriptor and the pinned revision disagree.
  """

  use Mix.Task

  @descriptor "priv/proto/temporal_core.binpb"
  @revision_file "priv/proto/temporal_core.revision"
  @cargo_lock "native/temporalex_nif/Cargo.lock"

  @roots [
    "local/temporal/sdk/core/core_interface.proto",
    "api_upstream/temporal/api/workflowservice/v1/request_response.proto"
  ]

  @includes ["api_upstream", "local", "google", "."]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [src: :string])

    revision = pinned_revision!()
    protos = Keyword.get_lazy(opts, :src, fn -> cargo_checkout!(revision) end) |> proto_root!()

    protoc!(protos)
    File.write!(@revision_file, revision <> "\n")

    Mix.shell().info("wrote #{@descriptor} from #{String.slice(revision, 0, 7)}")
  end

  @doc false
  def pinned_revision! do
    case Regex.run(
           ~r/name = "temporalio-client".*?source = "[^"]*#([0-9a-f]{40})"/s,
           read!(@cargo_lock)
         ) do
      [_, revision] -> revision
      nil -> Mix.raise("no temporalio-client git revision in #{@cargo_lock}")
    end
  end

  @doc false
  def committed_revision do
    case File.read(@revision_file) do
      {:ok, contents} -> String.trim(contents)
      {:error, _} -> nil
    end
  end

  defp read!(path) do
    File.read!(Path.join(File.cwd!(), path))
  end

  defp cargo_checkout!(revision) do
    short = String.slice(revision, 0, 7)

    Path.join([System.user_home!(), ".cargo/git/checkouts/sdk-rust-*", short])
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil ->
        Mix.raise("""
        no Cargo checkout of sdk-rust #{short}. Run `mix compile` to fetch it, \
        or pass --src pointing at a clone checked out at that revision.
        """)

      path ->
        path
    end
  end

  # The tree moved in v0.7.0 — it was `sdk-core-protos/protos`, and is now
  # `crates/protos/protos`.
  defp proto_root!(source) do
    ["crates/protos/protos", "sdk-core-protos/protos", "protos"]
    |> Enum.map(&Path.join(source, &1))
    |> Enum.find(&File.dir?/1)
    |> case do
      nil -> Mix.raise("no proto tree under #{source}")
      path -> path
    end
  end

  defp protoc!(protos) do
    args =
      Enum.flat_map(@includes, &["-I", Path.join(protos, &1)]) ++
        ["--include_imports", "--descriptor_set_out=#{@descriptor}"] ++
        Enum.map(@roots, &Path.join(protos, &1))

    case System.cmd("protoc", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> Mix.raise("protoc exited #{code}:\n\n#{output}")
    end
  end
end
