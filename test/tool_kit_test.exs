defmodule ToolKitTest do
  use ExUnit.Case, async: true
  doctest ToolKit

  describe "version/0" do
    test "returns the version from mix.exs" do
      assert ToolKit.version() == Mix.Project.config()[:version]
    end
  end
end
