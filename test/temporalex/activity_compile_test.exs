defmodule Temporalex.ActivityCompileTest do
  use ExUnit.Case, async: true

  describe "compile-time enforcement" do
    test "module with perform/1 generates perform/2 wrapper" do
      Code.compile_string("""
      defmodule TestPerform1Only#{System.unique_integer([:positive])} do
        use Temporalex.Activity

        @impl true
        def perform(%{name: name}), do: {:ok, name}
      end
      """)
    end

    test "module with perform/2 compiles without wrapper" do
      Code.compile_string("""
      defmodule TestPerform2Only#{System.unique_integer([:positive])} do
        use Temporalex.Activity

        @impl true
        def perform(_ctx, %{name: name}), do: {:ok, name}
      end
      """)
    end

    test "module with both perform/1 and perform/2 raises CompileError" do
      assert_raise CompileError, ~r/defines both perform\/1 and perform\/2/, fn ->
        Code.compile_string("""
        defmodule TestBothPerform#{System.unique_integer([:positive])} do
          use Temporalex.Activity

          @impl true
          def perform(%{name: name}), do: {:ok, name}

          @impl true
          def perform(_ctx, %{name: name}), do: {:ok, name}
        end
        """)
      end
    end

    test "module with neither perform/1 nor perform/2 raises CompileError" do
      assert_raise CompileError, ~r/must implement perform\/1 or perform\/2/, fn ->
        Code.compile_string("""
        defmodule TestNoPerform#{System.unique_integer([:positive])} do
          use Temporalex.Activity
        end
        """)
      end
    end

    test "perform/1 module has __activity_type__" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule TestActivityType#{System.unique_integer([:positive])} do
          use Temporalex.Activity
          @impl true
          def perform(_input), do: {:ok, nil}
        end
        """)

      assert is_binary(mod.__activity_type__())
    end

    test "module-level defaults are stored" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule TestDefaults#{System.unique_integer([:positive])} do
          use Temporalex.Activity,
            start_to_close_timeout: 15_000,
            heartbeat_timeout: 5_000

          @impl true
          def perform(_input), do: {:ok, nil}
        end
        """)

      defaults = mod.__activity_defaults__()
      assert defaults[:start_to_close_timeout] == 15_000
      assert defaults[:heartbeat_timeout] == 5_000
    end
  end
end
