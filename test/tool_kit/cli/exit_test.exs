defmodule ToolKit.CLI.ExitTest do
  use ExUnit.Case

  alias ToolKit.CLI.Exit

  describe "exit_with_code/2 in test mode" do
    setup do
      Application.put_env(:tool_kit_exit_test, :test_mode, true)
      on_exit(fn -> Application.delete_env(:tool_kit_exit_test, :test_mode) end)
      :ok
    end

    test "throws the exit code instead of halting" do
      assert catch_throw(Exit.exit_with_code(:tool_kit_exit_test, 0)) == {:cli_test_exit, 0}
      assert catch_throw(Exit.exit_with_code(:tool_kit_exit_test, 1)) == {:cli_test_exit, 1}
    end
  end
end
