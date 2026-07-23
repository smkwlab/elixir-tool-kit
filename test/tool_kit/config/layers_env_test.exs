defmodule ToolKit.Config.LayersEnvTest do
  # System.put_env を使うため async: false
  use ExUnit.Case, async: false

  alias ToolKit.Config.Layers

  @prefix "TK_LAYERS_TEST"
  @env_vars [
    "#{@prefix}_CSV_PATH",
    "#{@prefix}_GITHUB_ORG",
    "#{@prefix}_REGISTRY_REPO",
    "#{@prefix}_TEST_STUDENT_IDS",
    "#{@prefix}_LOG_LEVEL",
    "#{@prefix}_CACHE_ENABLED",
    "#{@prefix}_CACHE_TTL_HOURS",
    "#{@prefix}_API_TIMEOUT"
  ]

  setup do
    Enum.each(@env_vars, &System.delete_env/1)
    on_exit(fn -> Enum.each(@env_vars, &System.delete_env/1) end)
    :ok
  end

  @env_spec %{
    csv_path: :string,
    github_org: :string,
    registry_repo: :string,
    test_student_ids: :string_list,
    log_level: :string,
    cache: %{enabled: :boolean, ttl_hours: :integer},
    api: %{timeout_seconds: {:integer, "TIMEOUT"}}
  }

  describe "read_env/2" do
    test "reads and converts each declared type" do
      System.put_env("#{@prefix}_CSV_PATH", "/custom/path.csv")
      System.put_env("#{@prefix}_GITHUB_ORG", "custom_org")
      System.put_env("#{@prefix}_TEST_STUDENT_IDS", "k99rs001, k99rs002")
      System.put_env("#{@prefix}_CACHE_ENABLED", "false")
      System.put_env("#{@prefix}_CACHE_TTL_HOURS", "2")
      System.put_env("#{@prefix}_API_TIMEOUT", "30")
      System.put_env("#{@prefix}_LOG_LEVEL", "debug")

      assert {:ok, config} = Layers.read_env(@prefix, @env_spec)
      assert config.csv_path == "/custom/path.csv"
      assert config.github_org == "custom_org"
      assert config.test_student_ids == ["k99rs001", "k99rs002"]
      assert config.cache.enabled == false
      assert config.cache.ttl_hours == 2
      assert config.api.timeout_seconds == 30
      assert config.log_level == "debug"
    end

    test "returns an empty map when no environment variables are set" do
      assert Layers.read_env(@prefix, @env_spec) == {:ok, %{}}
    end

    test "omits nested keys when none of their variables are set" do
      System.put_env("#{@prefix}_GITHUB_ORG", "solo")

      assert Layers.read_env(@prefix, @env_spec) == {:ok, %{github_org: "solo"}}
    end

    test "a string_list value is split on commas, trimmed, and blanks removed" do
      System.put_env("#{@prefix}_TEST_STUDENT_IDS", " k99rs001 ,, k99rs002 ,")

      assert {:ok, %{test_student_ids: ["k99rs001", "k99rs002"]}} =
               Layers.read_env(@prefix, @env_spec)
    end

    test "boolean accepts only true/false" do
      System.put_env("#{@prefix}_CACHE_ENABLED", "invalid")

      assert {:error, message} = Layers.read_env(@prefix, @env_spec)
      assert message =~ "#{@prefix}_CACHE_ENABLED"
    end

    test "integer rejects non-integer values" do
      System.put_env("#{@prefix}_CACHE_TTL_HOURS", "2h")

      assert {:error, message} = Layers.read_env(@prefix, @env_spec)
      assert message =~ "#{@prefix}_CACHE_TTL_HOURS"
    end

    test "a custom name overrides the derived leaf segment" do
      System.put_env("#{@prefix}_API_TIMEOUT", "45")

      assert {:ok, %{api: %{timeout_seconds: 45}}} = Layers.read_env(@prefix, @env_spec)
    end
  end

  describe "resolve/2" do
    @defaults %{
      csv_path: nil,
      github_org: nil,
      registry_repo: nil,
      log_level: "info",
      cache: %{enabled: true, ttl_hours: 1, max_size_mb: 50},
      api: %{timeout_seconds: 15, max_concurrent: 8}
    }

    @tag :tmp_dir
    test "merges defaults < file < env < cli", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.yml")

      File.write!(path, """
      csv_path: /file/path.csv
      registry_repo: file/repo
      log_level: warn
      """)

      System.put_env("#{@prefix}_REGISTRY_REPO", "env/repo")

      assert {:ok, config} =
               Layers.resolve(@defaults,
                 file: path,
                 env: {@prefix, @env_spec},
                 cli: %{registry_repo: "cli/repo"}
               )

      # CLI > env > file
      assert config.registry_repo == "cli/repo"
      # file > defaults
      assert config.csv_path == "/file/path.csv"
      assert config.log_level == "warn"
      # defaults のみ
      assert config.api.timeout_seconds == 15
    end

    @tag :tmp_dir
    test "a single nested env var does not clobber file cache settings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.yml")

      File.write!(path, """
      cache:
        enabled: false
        max_size_mb: 99
      """)

      System.put_env("#{@prefix}_CACHE_TTL_HOURS", "5")

      assert {:ok, config} =
               Layers.resolve(@defaults, file: path, env: {@prefix, @env_spec})

      assert config.cache.enabled == false
      assert config.cache.max_size_mb == 99
      assert config.cache.ttl_hours == 5
    end

    @tag :tmp_dir
    test "file keys unknown to the defaults are dropped", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.yml")
      File.write!(path, "bogus_key: 1\nlog_level: debug\n")

      assert {:ok, config} = Layers.resolve(@defaults, file: path)
      assert config.log_level == "debug"
      refute Map.has_key?(config, :bogus_key)
      refute Map.has_key?(config, "bogus_key")
    end

    @tag :tmp_dir
    test "a missing file falls back to defaults", %{tmp_dir: tmp_dir} do
      assert {:ok, config} = Layers.resolve(@defaults, file: Path.join(tmp_dir, "missing.yml"))
      assert config == @defaults
    end

    test "file: nil skips the file layer" do
      assert Layers.resolve(@defaults) == {:ok, @defaults}
    end

    @tag :tmp_dir
    test "a parse failure is returned as an error", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "broken.yml")
      File.write!(path, "key: [unclosed")

      assert {:error, {:parse_error, ^path}} = Layers.resolve(@defaults, file: path)
    end

    test "an invalid env value is returned as an error" do
      System.put_env("#{@prefix}_CACHE_ENABLED", "invalid")

      assert {:error, message} = Layers.resolve(@defaults, env: {@prefix, @env_spec})
      assert message =~ "#{@prefix}_CACHE_ENABLED"
    end
  end
end
