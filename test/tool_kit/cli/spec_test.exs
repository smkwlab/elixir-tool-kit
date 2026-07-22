defmodule ToolKit.CLI.SpecTest do
  use ExUnit.Case, async: true

  alias ToolKit.CLI.Spec
  alias ToolKit.Test.RegistryManagerSpecFixture, as: Fixture

  @fixtures_dir Path.expand("../../fixtures/registry_manager_help", __DIR__)

  setup_all do
    %{spec: Fixture.spec()}
  end

  describe "find_command/2" do
    test "resolves names and aliases", %{spec: spec} do
      assert Spec.find_command(spec, "list").name == "list"
      assert Spec.find_command(spec, "ls").name == "list"
      assert Spec.find_command(spec, "rm").name == "remove"
      assert Spec.find_command(spec, "cache-status").name == "cache"
      assert Spec.find_command(spec, "unknown") == nil
    end
  end

  describe "catalog integrity" do
    test "aliases are unique", %{spec: spec} do
      aliases = Keyword.keys(Spec.aliases(spec))
      assert aliases == Enum.uniq(aliases)
    end

    test "strict switches cover every option referenced by a command", %{spec: spec} do
      switch_names = spec |> Spec.strict_switches() |> Keyword.keys() |> MapSet.new()

      for command <- spec.commands, option <- Spec.options_for(spec, command) do
        assert MapSet.member?(switch_names, option.name),
               "option #{option.name} of #{command.name} missing from strict switches"
      end
    end

    test "unknown option names in a command spec raise with the key", %{spec: spec} do
      assert_raise KeyError, fn ->
        Spec.options_for(spec, %{options: [:nonexistent_option]})
      end

      assert_raise KeyError, fn ->
        Spec.options_for(spec, %{options: [{:nonexistent_option, %{values: ["x"]}}]})
      end
    end

    test "integer options derive strict switches and render a VALUE placeholder" do
      spec = %Spec{
        tool_name: "demo",
        tool_summary: "demo tool",
        option_catalog: %{
          help: %{type: :boolean, alias: :h, values: nil, doc: "help"},
          jobs: %{type: :integer, alias: nil, values: nil, doc: "並列数"}
        },
        global_option_names: [:help],
        commands: [
          %{
            name: "run",
            aliases: [],
            usage: ["run"],
            summary: "run",
            options: [:jobs],
            examples: ["run --jobs 4"]
          }
        ]
      }

      assert {:jobs, :integer} in Spec.strict_switches(spec)
      assert Spec.render_command_help(spec, "run") =~ "--jobs VALUE"
      assert Spec.validate_opts(spec, "run", jobs: 4) == :ok

      # 整数でない値の拒否は OptionParser(strict)の責務で、
      # Parser がパース段階のエラーに変換する
      assert {:error, message} = ToolKit.CLI.Parser.parse(spec, ["run", "--jobs", "four"])
      assert message =~ "--jobs"
    end

    test "command option overrides replace values and doc", %{spec: spec} do
      list_command = Spec.find_command(spec, "list")
      sort = spec |> Spec.options_for(list_command) |> Enum.find(&(&1.name == :sort))

      assert sort.values == ["name", "time"]
      assert sort.doc =~ "デフォルト"
    end
  end

  describe "allowed_for/2" do
    test "global options are allowed for every command", %{spec: spec} do
      for command <- spec.commands do
        allowed = Spec.allowed_for(spec, command.name)

        for global <- spec.global_option_names do
          assert MapSet.member?(allowed, global)
        end
      end
    end

    test "command-local options are not allowed elsewhere", %{spec: spec} do
      refute MapSet.member?(Spec.allowed_for(spec, "add"), :format)
      refute MapSet.member?(Spec.allowed_for(spec, "list"), :state)
      refute MapSet.member?(Spec.allowed_for(spec, "remove"), :force)
      assert MapSet.member?(Spec.allowed_for(spec, "list"), :format)
      assert MapSet.member?(Spec.allowed_for(spec, "pr-status"), :state)
    end

    test "returns nil for unknown commands", %{spec: spec} do
      assert Spec.allowed_for(spec, "unknown") == nil
    end
  end

  describe "validate_opts/3" do
    test "accepts valid options and enum values", %{spec: spec} do
      assert :ok = Spec.validate_opts(spec, "list", format: "json", type: "wr")
    end

    test "rejects options that do not belong to the command", %{spec: spec} do
      assert {:error, message} = Spec.validate_opts(spec, "add", format: "json")
      assert message =~ "--format"
      assert message =~ "add"
    end

    test "rejects invalid enum values", %{spec: spec} do
      assert {:error, message} = Spec.validate_opts(spec, "list", type: "bogus")
      assert message =~ "bogus"
      assert message =~ "wr"
    end

    test "reports all violations at once", %{spec: spec} do
      assert {:error, message} = Spec.validate_opts(spec, "list", type: "bogus", state: "open")
      assert message =~ "--type"
      assert message =~ "--state"
    end

    test "per-command enum overrides are validated", %{spec: spec} do
      assert :ok = Spec.validate_opts(spec, "list", sort: "time")
      assert {:error, message} = Spec.validate_opts(spec, "list", sort: "updated")
      assert message =~ "name, time"

      assert :ok = Spec.validate_opts(spec, "pr-status", sort: "updated")
      assert {:error, _} = Spec.validate_opts(spec, "pr-status", sort: "time")
    end

    test "underscored option names are rendered with hyphens in errors", %{spec: spec} do
      assert {:error, message} = Spec.validate_opts(spec, "list", review_requested: true)
      assert message =~ "--review-requested"
    end

    test "unknown command passes through (dispatch handles it)", %{spec: spec} do
      assert :ok = Spec.validate_opts(spec, "unknown", format: "json")
      assert :ok = Spec.validate_opts(spec, nil, format: "json")
    end
  end

  describe "byte-identical help against registry-manager escript output" do
    # 期待値は registry-manager escript の実出力（IO.puts 経由のため末尾に改行 1 個が付く）
    test "render_help/1 reproduces the global help", %{spec: spec} do
      expected = File.read!(Path.join(@fixtures_dir, "help-global.txt"))
      assert Spec.render_help(spec) <> "\n" == expected
    end

    for command_name <- [
          "init",
          "add",
          "update",
          "remove",
          "protect",
          "list",
          "validate",
          "cache",
          "infer-student-id",
          "edit",
          "pr-status",
          "propagate-workflow",
          "archive"
        ] do
      test "render_command_help/2 reproduces `#{command_name} --help`", %{spec: spec} do
        expected = File.read!(Path.join(@fixtures_dir, "help-#{unquote(command_name)}.txt"))
        assert Spec.render_command_help(spec, unquote(command_name)) <> "\n" == expected
      end
    end

    test "command help resolves aliases and unknown commands", %{spec: spec} do
      assert Spec.render_command_help(spec, "ls") == Spec.render_command_help(spec, "list")
      assert Spec.render_command_help(spec, "unknown") == nil
    end
  end
end
