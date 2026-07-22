defmodule ToolKit.CLI.ParserTest do
  use ExUnit.Case, async: true

  alias ToolKit.CLI.Parser
  alias ToolKit.Test.RegistryManagerSpecFixture, as: Fixture

  setup_all do
    %{spec: Fixture.spec()}
  end

  describe "default command" do
    test "empty argv falls back to the default command", %{spec: spec} do
      assert Parser.parse(spec, [], default_command: "list") == {:command, "list", [], []}
    end

    test "options are validated against the default command", %{spec: spec} do
      assert {:command, "list", [], [long: true]} =
               Parser.parse(spec, ["--long"], default_command: "list")

      assert {:error, message} = Parser.parse(spec, ["--force"], default_command: "list")
      assert message =~ "--force"
    end

    test "--help wins over the default command", %{spec: spec} do
      assert Parser.parse(spec, ["--help"], default_command: "list") == :help
    end

    test "an explicit command is unaffected", %{spec: spec} do
      assert {:command, "validate", [], []} =
               Parser.parse(spec, ["validate"], default_command: "list")
    end
  end

  describe "help short-circuit" do
    test "no arguments renders global help", %{spec: spec} do
      assert Parser.parse(spec, []) == :help
    end

    test "--help renders global help", %{spec: spec} do
      assert Parser.parse(spec, ["--help"]) == :help
      assert Parser.parse(spec, ["-h"]) == :help
    end

    test "<command> --help targets the canonical command", %{spec: spec} do
      assert Parser.parse(spec, ["list", "--help"]) == {:help_command, "list"}
      assert Parser.parse(spec, ["ls", "--help"]) == {:help_command, "list"}
      assert Parser.parse(spec, ["cache-clear", "--help"]) == {:help_command, "cache"}
    end

    test "unknown command with --help falls back to global help", %{spec: spec} do
      assert Parser.parse(spec, ["unknown", "--help"]) == :help
    end
  end

  describe "option validation" do
    test "unknown switches are an error", %{spec: spec} do
      assert {:error, message} = Parser.parse(spec, ["list", "--bogus"])
      assert message =~ "不明なオプション"
      assert message =~ "--bogus"
    end

    test "options not belonging to the command are an error", %{spec: spec} do
      assert {:error, message} = Parser.parse(spec, ["add", "x", "--format", "json"])
      assert message =~ "--format"
    end

    test "enum violations are an error", %{spec: spec} do
      assert {:error, message} = Parser.parse(spec, ["list", "--type", "bogus"])
      assert message =~ "bogus"
    end
  end

  describe "command passthrough" do
    test "returns the invoked name, positional args, and parsed opts", %{spec: spec} do
      assert {:command, "add", ["k21rs001-sotsuron"], opts} =
               Parser.parse(spec, ["add", "k21rs001-sotsuron", "--dry-run"])

      assert opts[:dry_run] == true
    end

    test "aliases are passed through as invoked (tool normalizes them)", %{spec: spec} do
      assert {:command, "ls", [], [long: true]} = Parser.parse(spec, ["ls", "--long"])
      assert {:command, "cache-status", [], []} = Parser.parse(spec, ["cache-status"])
    end

    test "short aliases map to their long option", %{spec: spec} do
      assert {:command, "list", [], opts} = Parser.parse(spec, ["list", "-l", "-r"])
      assert opts[:long] == true
      assert opts[:reverse] == true
    end

    test "single-char option keeps its own name", %{spec: spec} do
      assert {:command, "list", [], opts} = Parser.parse(spec, ["list", "-t"])
      assert opts[:t] == true
    end

    test "unknown commands pass through for the tool to handle", %{spec: spec} do
      assert {:command, "unknown", [], []} = Parser.parse(spec, ["unknown"])
    end

    test "negation switches on boolean options are accepted", %{spec: spec} do
      assert {:command, "add", ["x"], opts} =
               Parser.parse(spec, ["add", "x", "--no-review-flow"])

      assert opts[:review_flow] == false
    end
  end
end
