defmodule ToolKit.Config.Layers do
  @moduledoc """
  設定レイヤの読み込みとマージ(機構のみ)。

  defaults ⊕ YAML ファイル ⊕ 環境変数 ⊕ CLI オーバーライドの 4 層を
  この順の後勝ちでマージする。保持方式(struct / Agent / Application env)と
  設定スキーマはツール側の責務で、本モジュールは純関数だけを提供する。

  ## 使い方

      defaults = %{registry_repo: nil, cache: %{enabled: true, ttl_hours: 1}}

      env_spec = %{
        registry_repo: :string,
        cache: %{enabled: :boolean, ttl_hours: :integer}
      }

      {:ok, config} =
        ToolKit.Config.Layers.resolve(defaults,
          file: ToolKit.Config.Layers.default_config_path("mytool"),
          env: {"MYTOOL", env_spec},
          cli: %{registry_repo: "cli/repo"}
        )

  ## 環境変数 spec

  キー(atom)→ 型の入れ子マップで宣言する。変数名は
  `<prefix>_<キー経路の大文字連結>`(例: `MYTOOL_CACHE_TTL_HOURS`)。
  `{型, "SUFFIX"}` で末端セグメント(キー名由来の部分)だけを差し替えられる
  (例: `api: %{timeout_seconds: {:integer, "TIMEOUT"}}` → `MYTOOL_API_TIMEOUT`)。

  型は `:string` / `:integer` / `:boolean` /
  `:string_list`(カンマ区切り・trim・空要素除去)。
  """

  @typedoc "環境変数値の変換型"
  @type env_type :: :string | :integer | :boolean | :string_list

  @typedoc "環境変数 spec(キー → 型 | {型, 派生名の差し替え} | 入れ子 spec)"
  @type env_spec :: %{atom() => env_type() | {env_type(), String.t()} | map()}

  @typedoc "resolve/2 と load_file/1 のエラー理由"
  @type error_reason :: {:parse_error, String.t()} | String.t()

  # [^/\s]+ がスラッシュを含まないため「/ をちょうど 1 つ含む」形式のみ許可
  # (owner/repo/extra のような 3 セグメント以上は不一致)
  @owner_repo_regex ~r{\A[^/\s]+/[^/\s]+\z}

  @doc """
  defaults ⊕ ファイル ⊕ 環境変数 ⊕ CLI の 4 層を後勝ちでマージする。

  ## オプション

  - `:file` — YAML 設定ファイルのパス。不存在は無視して defaults に
    フォールバック、パース失敗は `{:error, {:parse_error, path}}`。
    読み込んだ内容は defaults をテンプレートに `normalize_keys/2` で
    正規化される(defaults に無いキーは落ちる)
  - `:env` — `{prefix, env_spec}`。変換失敗は `{:error, message}`
  - `:cli` — CLI オーバーライドの map(atom キー)

  マージ規則は `merge/1` を参照(nil は上書きしない・入れ子 map は再帰マージ)。
  """
  @spec resolve(map(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def resolve(defaults, opts \\ []) when is_map(defaults) do
    with {:ok, file_layer} <- file_layer(Keyword.get(opts, :file), defaults),
         {:ok, env_layer} <- env_layer(Keyword.get(opts, :env)) do
      {:ok, merge([defaults, file_layer, env_layer, Keyword.get(opts, :cli, %{})])}
    end
  end

  defp file_layer(nil, _defaults), do: {:ok, %{}}

  defp file_layer(path, defaults) do
    case load_file(path) do
      {:ok, raw} -> {:ok, normalize_keys(raw, defaults)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp env_layer(nil), do: {:ok, %{}}
  defp env_layer({prefix, spec}), do: read_env(prefix, spec)

  @doc """
  YAML 設定ファイルを読み込む。

  ファイル不存在は `{:ok, %{}}`(defaults へのフォールバック)、
  パース失敗と mapping 以外の内容は `{:error, {:parse_error, path}}`。
  YAML 1.2 は JSON の上位互換なので旧 config.json もそのまま読める。
  """
  @spec load_file(String.t()) :: {:ok, map()} | {:error, {:parse_error, String.t()}}
  def load_file(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, config} when is_map(config) -> {:ok, config}
        _ -> {:error, {:parse_error, path}}
      end
    else
      {:ok, %{}}
    end
  end

  @doc """
  テンプレート(通常は defaults)に沿って raw map のキーを atom に正規化する。

  テンプレートにあるキーだけを拾い(string / atom どちらのキーでも可、
  両方あれば atom が優先)、テンプレート側が map のキーは再帰する。
  テンプレートに無いキーは落とす(未知キーで atom を無制限に生成しない)。
  """
  @spec normalize_keys(map(), map()) :: map()
  def normalize_keys(raw, template) when is_map(raw) and is_map(template) do
    Enum.reduce(template, %{}, fn {key, template_value}, acc ->
      case fetch_raw(raw, key) do
        {:ok, value} -> Map.put(acc, key, normalize_value(value, template_value))
        :error -> acc
      end
    end)
  end

  defp fetch_raw(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(raw, Atom.to_string(key))
    end
  end

  defp normalize_value(value, template_value) when is_map(value) and is_map(template_value) do
    normalize_keys(value, template_value)
  end

  defp normalize_value(value, _template_value), do: value

  @doc """
  レイヤ(map のリスト)を先頭から順に後勝ちでマージする。

  - 後のレイヤの nil 値は既存値を上書きしない(「未設定」を表す。
    キー自体が無ければ nil のまま入り、defaults の nil キーは保持される)
  - 両方が map の値は再帰マージ(env の 1 変数がファイルの入れ子設定を
    丸ごと潰さない)
  - それ以外の値は置き換え

  ## Examples

      iex> ToolKit.Config.Layers.merge([%{a: 1, c: %{x: 1, y: 2}}, %{a: 2, c: %{y: 9}}])
      %{a: 2, c: %{x: 1, y: 9}}

  """
  @spec merge([map()]) :: map()
  def merge(layers) do
    Enum.reduce(layers, %{}, &merge_layer(&2, &1))
  end

  defp merge_layer(base, layer) do
    Enum.reduce(layer, base, &merge_entry(&2, &1))
  end

  # nil は既存値を上書きしない(「未設定」)。キー自体が無ければ nil のまま入る
  # (defaults 層の csv_path: nil などを保持するため)
  defp merge_entry(acc, {key, nil}), do: Map.put_new(acc, key, nil)

  defp merge_entry(acc, {key, value}) do
    Map.update(acc, key, value, &merge_value(&1, value))
  end

  defp merge_value(base, value) when is_map(base) and is_map(value) do
    merge_layer(base, value)
  end

  defp merge_value(_base, value), do: value

  @doc """
  環境変数を spec に沿って読み込み、設定されたキーだけの map を返す。

  変数名の派生と型変換はモジュール doc の「環境変数 spec」を参照。
  変換失敗(不正な integer / boolean)は `{:error, message}`。
  """
  @spec read_env(String.t(), env_spec()) :: {:ok, map()} | {:error, String.t()}
  def read_env(prefix, spec) when is_binary(prefix) and is_map(spec) do
    {:ok, read_env_map(prefix, spec)}
  catch
    :throw, {:invalid_env, message} -> {:error, message}
  end

  defp read_env_map(prefix, spec) do
    Enum.reduce(spec, %{}, fn {key, entry}, acc ->
      put_env_entry(acc, key, entry, prefix)
    end)
  end

  # 入れ子 spec: プレフィックスにキー名を連ねて再帰。1 変数も無ければキーごと省く
  defp put_env_entry(acc, key, nested, prefix) when is_map(nested) do
    case read_env_map("#{prefix}_#{env_segment(key)}", nested) do
      empty when empty == %{} -> acc
      nested_map -> Map.put(acc, key, nested_map)
    end
  end

  defp put_env_entry(acc, key, {type, suffix}, prefix) do
    put_env_value(acc, key, type, "#{prefix}_#{suffix}")
  end

  defp put_env_entry(acc, key, type, prefix) when is_atom(type) do
    put_env_value(acc, key, type, "#{prefix}_#{env_segment(key)}")
  end

  defp env_segment(key), do: key |> Atom.to_string() |> String.upcase()

  defp put_env_value(acc, key, type, var) do
    case System.get_env(var) do
      nil -> acc
      raw -> Map.put(acc, key, convert_env!(type, raw, var))
    end
  end

  defp convert_env!(:string, raw, _var), do: raw

  defp convert_env!(:boolean, "true", _var), do: true
  defp convert_env!(:boolean, "false", _var), do: false

  defp convert_env!(:boolean, raw, var) do
    throw({:invalid_env, "invalid boolean for #{var}: #{raw} (expected true/false)"})
  end

  defp convert_env!(:integer, raw, var) do
    case Integer.parse(raw) do
      {value, ""} -> value
      _ -> throw({:invalid_env, "invalid integer for #{var}: #{raw}"})
    end
  end

  defp convert_env!(:string_list, raw, _var) do
    raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @doc """
  `owner/repo` 形式の owner 部を返す。形式外は nil。

  ## Examples

      iex> ToolKit.Config.Layers.owner_from_repo("acme/registry-data")
      "acme"

      iex> ToolKit.Config.Layers.owner_from_repo("acme")
      nil

  """
  @spec owner_from_repo(String.t() | nil) :: String.t() | nil
  def owner_from_repo(repo) when is_binary(repo) do
    case String.split(repo, "/") do
      [owner, _repo] when owner != "" -> owner
      _ -> nil
    end
  end

  def owner_from_repo(_repo), do: nil

  @doc """
  github_org が未設定(nil / 空文字列)なら registry_repo の owner を導出する。

  明示設定が常に優先。repo も無ければ nil を返し、消費点での明示エラーは
  ツール側の責務(他 org への静かな誤対象を防ぐため既定 org は持たない)。
  """
  @spec derive_github_org(String.t() | nil, String.t() | nil) :: String.t() | nil
  def derive_github_org(org, repo) when org in [nil, ""], do: owner_from_repo(repo)
  def derive_github_org(org, _repo), do: org

  @doc """
  値が `owner/repo` 形式かどうかを返す。

  ## Examples

      iex> ToolKit.Config.Layers.valid_owner_repo?("owner/repo")
      true

      iex> ToolKit.Config.Layers.valid_owner_repo?("owner/repo/extra")
      false

  """
  @spec valid_owner_repo?(String.t()) :: boolean()
  def valid_owner_repo?(value) when is_binary(value) do
    Regex.match?(@owner_repo_regex, value)
  end

  @doc """
  組織の名簿 CSV の規約パス `~/.config/<org>/students.csv` を返す(存在は見ない)。
  """
  @spec conventional_csv_path(String.t(), String.t()) :: String.t()
  def conventional_csv_path(github_org, home \\ System.user_home!())
      when is_binary(github_org) and is_binary(home) do
    Path.join([home, ".config", github_org, "students.csv"])
  end

  @doc """
  規約パスの名簿 CSV が存在すればそのパスを、無ければ nil を返す。

  org / home が使えない環境(未設定・HOME なし)では nil(規約導出をスキップ)。
  """
  @spec find_conventional_csv(String.t() | nil, String.t() | nil) :: String.t() | nil
  def find_conventional_csv(github_org, home \\ System.user_home())

  def find_conventional_csv(github_org, home)
      when is_binary(github_org) and github_org != "" and is_binary(home) do
    path = conventional_csv_path(github_org, home)
    if File.exists?(path), do: path, else: nil
  end

  def find_conventional_csv(_github_org, _home), do: nil

  @doc """
  パス先頭のチルダ(`~` / `~/...`)を home に展開する。それ以外はそのまま返す。

  ## Examples

      iex> ToolKit.Config.Layers.expand_home("~/.cache/tool", "/home/x")
      "/home/x/.cache/tool"

      iex> ToolKit.Config.Layers.expand_home("/abs/path", "/home/x")
      "/abs/path"

  """
  @spec expand_home(String.t(), String.t() | nil) :: String.t()
  def expand_home(path, home \\ System.user_home())
  def expand_home("~", home) when is_binary(home), do: home
  def expand_home("~/" <> rest, home) when is_binary(home), do: Path.join(home, rest)
  def expand_home(path, _home), do: path

  @doc """
  ツールの既定設定ファイルパス `~/.config/<tool>/config.yml` を返す。
  """
  @spec default_config_path(String.t(), String.t()) :: String.t()
  def default_config_path(tool_name, home \\ System.user_home!())
      when is_binary(tool_name) and is_binary(home) do
    Path.join([home, ".config", tool_name, "config.yml"])
  end

  @doc """
  候補リストから最初に存在するパスを返す(探索順の解決)。

  nil の候補(未指定の CLI パスなど)はスキップする。どれも存在しなければ nil。

  典型例: `first_existing([cli_path, "./config/<tool>.yml", default_config_path(tool)])`
  """
  @spec first_existing([String.t() | nil]) :: String.t() | nil
  def first_existing(candidates) when is_list(candidates) do
    Enum.find(candidates, fn path -> is_binary(path) and File.exists?(path) end)
  end
end
