defmodule ToolKitTest do
  use ExUnit.Case, async: true
  doctest ToolKit

  describe "version/0" do
    test "returns a semver version string" do
      assert ToolKit.version() =~ ~r/^\d+\.\d+\.\d+$/
    end
  end
end
