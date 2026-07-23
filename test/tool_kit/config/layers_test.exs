defmodule ToolKit.Config.LayersTest do
  use ExUnit.Case, async: true
  doctest ToolKit.Config.Layers

  alias ToolKit.Config.Layers

  describe "load_file/1" do
    @tag :tmp_dir
    test "parses a YAML config file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.yml")

      File.write!(path, """
      # comment line
      github_org: yamlorg
      registry_repo: yamlorg/thesis-student-registry
      cache:
        enabled: false
      """)

      assert {:ok, config} = Layers.load_file(path)
      assert config["github_org"] == "yamlorg"
      assert config["registry_repo"] == "yamlorg/thesis-student-registry"
      assert config["cache"]["enabled"] == false
    end

    @tag :tmp_dir
    test "parses legacy JSON content (YAML 1.2 superset)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.json")
      File.write!(path, ~s({"github_org": "jsonorg", "cache": {"enabled": false}}))

      assert {:ok, config} = Layers.load_file(path)
      assert config["github_org"] == "jsonorg"
      assert config["cache"]["enabled"] == false
    end

    @tag :tmp_dir
    test "returns an empty map when the file does not exist", %{tmp_dir: tmp_dir} do
      assert Layers.load_file(Path.join(tmp_dir, "missing.yml")) == {:ok, %{}}
    end

    @tag :tmp_dir
    test "returns an error when the file cannot be parsed", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "broken.yml")
      File.write!(path, "key: [unclosed")

      assert {:error, {:parse_error, ^path}} = Layers.load_file(path)
    end

    @tag :tmp_dir
    test "returns an error when the file is not a mapping", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "scalar.yml")
      File.write!(path, "just a string")

      assert {:error, {:parse_error, ^path}} = Layers.load_file(path)
    end
  end

  describe "normalize_keys/2" do
    @template %{csv_path: nil, log_level: "info", cache: %{enabled: true, ttl_hours: 1}}

    test "converts string keys known to the template into atoms" do
      raw = %{"csv_path" => "/a.csv", "log_level" => "debug"}

      assert Layers.normalize_keys(raw, @template) ==
               %{csv_path: "/a.csv", log_level: "debug"}
    end

    test "keeps atom keys as-is" do
      assert Layers.normalize_keys(%{log_level: "warn"}, @template) == %{log_level: "warn"}
    end

    test "drops keys unknown to the template" do
      assert Layers.normalize_keys(%{"unknown" => 1, "log_level" => "debug"}, @template) ==
               %{log_level: "debug"}
    end

    test "recurses into nested maps present in the template" do
      raw = %{"cache" => %{"enabled" => false, "bogus" => 9}}

      assert Layers.normalize_keys(raw, @template) == %{cache: %{enabled: false}}
    end

    test "an atom key wins when both atom and string keys are present" do
      raw = %{:log_level => "warn", "log_level" => "debug"}

      assert Layers.normalize_keys(raw, @template) == %{log_level: "warn"}
    end
  end

  describe "merge/1" do
    test "later layers win" do
      assert Layers.merge([%{a: 1}, %{a: 2}, %{a: 3}]) == %{a: 3}
    end

    test "keys absent from later layers keep earlier values" do
      assert Layers.merge([%{a: 1, b: 2}, %{b: 3}]) == %{a: 1, b: 3}
    end

    test "nil values in later layers do not override" do
      assert Layers.merge([%{a: 1}, %{a: nil}]) == %{a: 1}
    end

    test "nested maps merge instead of clobbering" do
      defaults = %{cache: %{enabled: true, ttl_hours: 1, max_size_mb: 50}}
      file = %{cache: %{enabled: false, max_size_mb: 99}}
      env = %{cache: %{ttl_hours: 5}}

      assert Layers.merge([defaults, file, env]) ==
               %{cache: %{enabled: false, ttl_hours: 5, max_size_mb: 99}}
    end

    test "a non-map value replaces a map value" do
      assert Layers.merge([%{a: %{b: 1}}, %{a: "flat"}]) == %{a: "flat"}
    end
  end

  describe "owner_from_repo/1" do
    test "extracts the owner from owner/repo" do
      assert Layers.owner_from_repo("acme/registry-data") == "acme"
    end

    test "returns nil for shapes without exactly one slash" do
      assert Layers.owner_from_repo("acme") == nil
      assert Layers.owner_from_repo("a/b/c") == nil
      assert Layers.owner_from_repo("/repo") == nil
      assert Layers.owner_from_repo(nil) == nil
    end
  end

  describe "derive_github_org/2" do
    test "derives the org from the repo owner when unset" do
      assert Layers.derive_github_org(nil, "acme/registry-data") == "acme"
      assert Layers.derive_github_org("", "acme/registry-data") == "acme"
    end

    test "an explicit org wins over the derived owner" do
      assert Layers.derive_github_org("explicit", "acme/registry-data") == "explicit"
    end

    test "returns nil when neither org nor repo is set" do
      assert Layers.derive_github_org(nil, nil) == nil
    end
  end

  describe "valid_owner_repo?/1" do
    test "accepts owner/repo and rejects other shapes" do
      assert Layers.valid_owner_repo?("owner/repo")
      refute Layers.valid_owner_repo?("owner")
      refute Layers.valid_owner_repo?("owner/repo/extra")
      refute Layers.valid_owner_repo?("owner /repo")
      refute Layers.valid_owner_repo?("/repo")
      refute Layers.valid_owner_repo?("owner/")
    end
  end

  describe "conventional_csv_path/2" do
    test "derives the roster path from the org" do
      assert Layers.conventional_csv_path("myorg", "/home/x") ==
               "/home/x/.config/myorg/students.csv"
    end
  end

  describe "find_conventional_csv/2" do
    @tag :tmp_dir
    test "returns the conventional path when the file exists", %{tmp_dir: home} do
      path = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "header\n")

      assert Layers.find_conventional_csv("testorg", home) == path
    end

    @tag :tmp_dir
    test "returns nil when the file does not exist", %{tmp_dir: home} do
      assert Layers.find_conventional_csv("testorg", home) == nil
    end

    @tag :tmp_dir
    test "returns nil when the org is nil or empty", %{tmp_dir: home} do
      assert Layers.find_conventional_csv(nil, home) == nil
      assert Layers.find_conventional_csv("", home) == nil
    end

    test "returns nil when the home directory is unavailable" do
      assert Layers.find_conventional_csv("testorg", nil) == nil
    end
  end

  describe "expand_home/2" do
    test "expands a bare tilde and tilde-prefixed paths" do
      assert Layers.expand_home("~", "/home/x") == "/home/x"
      assert Layers.expand_home("~/.cache/tool", "/home/x") == "/home/x/.cache/tool"
    end

    test "leaves other paths untouched" do
      assert Layers.expand_home("/abs/path", "/home/x") == "/abs/path"
      assert Layers.expand_home("relative/path", "/home/x") == "relative/path"
      assert Layers.expand_home("~user/path", "/home/x") == "~user/path"
    end

    test "leaves tilde paths untouched when home is unavailable" do
      assert Layers.expand_home("~/.cache/tool", nil) == "~/.cache/tool"
    end
  end

  describe "default_config_path/2" do
    test "returns ~/.config/<tool>/config.yml" do
      assert Layers.default_config_path("thesis-monitor", "/home/x") ==
               "/home/x/.config/thesis-monitor/config.yml"
    end
  end

  describe "default home arguments" do
    test "conventional_csv_path/1 uses the real home directory" do
      assert Layers.conventional_csv_path("myorg") ==
               Path.join([System.user_home!(), ".config", "myorg", "students.csv"])
    end

    test "default_config_path/1 uses the real home directory" do
      assert Layers.default_config_path("mytool") ==
               Path.join([System.user_home!(), ".config", "mytool", "config.yml"])
    end

    test "expand_home/1 expands against the real home directory" do
      assert Layers.expand_home("~/x") == Path.join(System.user_home!(), "x")
    end

    test "find_conventional_csv/1 returns nil for a nonexistent org" do
      assert Layers.find_conventional_csv("no-such-org-#{System.unique_integer([:positive])}") ==
               nil
    end
  end

  describe "first_existing/1" do
    @tag :tmp_dir
    test "returns the first existing candidate", %{tmp_dir: tmp_dir} do
      exists_late = Path.join(tmp_dir, "late.yml")
      exists_early = Path.join(tmp_dir, "early.yml")
      File.write!(exists_late, "a: 1\n")
      File.write!(exists_early, "a: 1\n")
      missing = Path.join(tmp_dir, "missing.yml")

      assert Layers.first_existing([missing, exists_early, exists_late]) == exists_early
    end

    @tag :tmp_dir
    test "skips nil candidates (unset CLI path)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.yml")
      File.write!(path, "a: 1\n")

      assert Layers.first_existing([nil, path]) == path
    end

    @tag :tmp_dir
    test "returns nil when no candidate exists", %{tmp_dir: tmp_dir} do
      assert Layers.first_existing([nil, Path.join(tmp_dir, "missing.yml")]) == nil
    end
  end
end
