defmodule ToolKit.Cache do
  @moduledoc """
  TTL 付きファイルキャッシュ(機構のみ)。

  (cache_dir, category, TTL)でパラメータ化した 2 層の API を提供する。
  キャッシュの用途(何をどのカテゴリに何秒入れるか)はツール側の責務。

  - 低レベル API — `put/3` / `get/2` / `delete/2` / `refresh/2` / `clear/1` /
    `status/2` / `stats/1`。エントリごとに JSON エンベロープ
    (`key` / `cached_at` / `expires_at` / `data`)を
    `<cache_dir>/<category>/<key>.json` へ保存し、`expires_at` で期限判定する
  - ergonomic API — `get_or_fetch/3`。生バイナリを
    `<cache_dir>/<category>/<key>` へ保存し、ファイル mtime で期限判定する。
    `ttl <= 0` は常にミス(`--no-cache` の実装手段)

  キャッシュは best-effort であり、ディレクトリ作成やファイル I/O の失敗で
  呼び出し元の処理を止めない(`put/3` はエラーをタプルで報告するが raise
  しない。`get_or_fetch/3` は保存失敗を無視して取得結果を返す)。
  書き込みは一時ファイル + rename のアトミック書き込みで、中断や並行実行で
  書きかけの内容がフレッシュなキャッシュとして残るのを防ぐ。

  ## オプション

  - `:cache_dir` — キャッシュディレクトリ(必須)
  - `:category` — カテゴリ = サブディレクトリ名(デフォルト `"default"`)
  - `:ttl` — TTL 秒(デフォルト 3600)

  キーは `[^A-Za-z0-9._-]` を `_` に置換してフラットなファイル名へ落とすため、
  `owner/repo` のようなリポジトリ名をそのままキーにできる。
  """

  @default_category "default"
  @default_ttl 3600

  @empty_stats %{total_entries: 0, total_size_bytes: 0, expired_entries: 0, valid_entries: 0}

  defmodule Status do
    @moduledoc """
    キャッシュエントリ 1 件の状態。
    """
    defstruct [:key, :cached_at, :expires_at, exists: false, expired: false, size_bytes: 0]

    @type t :: %__MODULE__{
            key: String.t(),
            exists: boolean(),
            expired: boolean(),
            cached_at: String.t() | nil,
            expires_at: String.t() | nil,
            size_bytes: non_neg_integer()
          }
  end

  @typedoc "全エントリの集計(`stats/1` の戻り値)"
  @type stats :: %{
          total_entries: non_neg_integer(),
          total_size_bytes: non_neg_integer(),
          expired_entries: non_neg_integer(),
          valid_entries: non_neg_integer()
        }

  @doc """
  低レベル API のキャッシュファイルパスを返す。

  `<cache_dir>/<category>/<サニタイズ済み key>.json`。
  """
  @spec cache_path(String.t(), keyword()) :: String.t()
  def cache_path(key, opts) do
    raw_path(key, opts) <> ".json"
  end

  @doc """
  データを TTL 付きで保存する。

  JSON エンベロープをアトミックに書き込む。失敗しても raise せず
  `{:error, {:json_encode_failed | :write_failed, reason}}` を返す。
  """
  @spec put(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def put(key, data, opts) do
    now = DateTime.utc_now()

    envelope = %{
      "key" => key,
      "cached_at" => DateTime.to_iso8601(now),
      "expires_at" => now |> expires_at(ttl(opts)) |> DateTime.to_iso8601(),
      "data" => data
    }

    with {:ok, json} <- encode(envelope) do
      atomic_write(cache_path(key, opts), json)
    end
  end

  @doc """
  保存済みデータを取り出す。

  有効なら `{:ok, data}`、それ以外は
  `{:error, :cache_miss | :cache_expired | :invalid_cache | :read_failed}`。
  """
  @spec get(String.t(), keyword()) ::
          {:ok, term()} | {:error, :cache_miss | :cache_expired | :invalid_cache | :read_failed}
  def get(key, opts) do
    case File.read(cache_path(key, opts)) do
      {:ok, content} -> decode_and_validate(content)
      {:error, :enoent} -> {:error, :cache_miss}
      {:error, _reason} -> {:error, :read_failed}
    end
  end

  @doc """
  エントリを削除する。存在しなくても `:ok`。
  """
  @spec delete(String.t(), keyword()) :: :ok
  def delete(key, opts) do
    _ = File.rm(cache_path(key, opts))
    :ok
  end

  @doc """
  エントリを破棄して次回アクセス時の再取得を強制する(`delete/2` と同義)。
  """
  @spec refresh(String.t(), keyword()) :: :ok
  def refresh(key, opts), do: delete(key, opts)

  @doc """
  カテゴリ配下の全エントリを削除する。
  """
  @spec clear(keyword()) :: :ok
  def clear(opts) do
    _ = File.rm_rf(category_dir(opts))
    :ok
  end

  @doc """
  エントリ 1 件の状態(存在・期限・サイズ・タイムスタンプ)を返す。

  エンベロープを読めないエントリは `expired: true` として扱う。
  """
  @spec status(String.t(), keyword()) :: Status.t()
  def status(key, opts) do
    path = cache_path(key, opts)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> existing_status(key, path, size)
      {:error, _reason} -> %Status{key: key}
    end
  end

  @doc """
  カテゴリ配下の全エントリ(`*.json`)の集計を返す。
  """
  @spec stats(keyword()) :: stats()
  def stats(opts) do
    dir = category_dir(opts)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce(@empty_stats, &accumulate_stats(Path.join(dir, &1), &2))

      {:error, _reason} ->
        @empty_stats
    end
  end

  @doc """
  ISO 8601 の `expires_at` が期限切れかを判定する。

  `nil` やパースできない値は期限切れとして扱う。
  """
  @spec expired?(String.t() | nil) :: boolean()
  def expired?(nil), do: true

  def expired?(expires_at_string) do
    case DateTime.from_iso8601(expires_at_string) do
      {:ok, expires_at, _offset} -> DateTime.compare(DateTime.utc_now(), expires_at) == :gt
      {:error, _reason} -> true
    end
  end

  @doc """
  key のキャッシュが TTL 内ならその内容を返し、無ければ `fetch_fn.()` を実行して
  結果が `{:ok, binary}` のときだけキャッシュへ保存して返す。

  期限はファイル mtime で判定し、`ttl <= 0` は常にミス。fetch の失敗や
  binary 以外の成功値はキャッシュしない(次回の呼び出しで再試行される)。
  保存の失敗は無視する(キャッシュは best-effort)。
  """
  @spec get_or_fetch(String.t(), (-> {:ok, binary()} | term()), keyword()) ::
          {:ok, binary()} | term()
  def get_or_fetch(key, fetch_fn, opts) do
    path = raw_path(key, opts)

    case read_fresh(path, ttl(opts)) do
      {:ok, content} -> {:ok, content}
      :miss -> fetch_and_store(fetch_fn, path)
    end
  end

  # --- 内部関数 ---

  defp ttl(opts), do: Keyword.get(opts, :ttl, @default_ttl)

  defp category_dir(opts) do
    Path.join(
      Keyword.fetch!(opts, :cache_dir),
      Keyword.get(opts, :category, @default_category)
    )
  end

  defp raw_path(key, opts), do: Path.join(category_dir(opts), sanitize(key))

  # キーに含まれる repo/path 区切りをフラットなファイル名に落とす
  defp sanitize(key), do: String.replace(key, ~r/[^A-Za-z0-9._-]/, "_")

  # round により小数 TTL(例: 0.5 秒)も秒精度で扱える
  defp expires_at(now, ttl), do: DateTime.add(now, round(ttl), :second)

  defp encode(envelope) do
    case Jason.encode(envelope, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  end

  # 一時ファイル + rename のアトミック書き込み
  defp atomic_write(path, content) do
    tmp = "#{path}.tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        # 後始末の失敗(tmp 未作成の :enoent 等)は無視する
        _ = File.rm(tmp)
        {:error, {:write_failed, reason}}
    end
  end

  defp decode_and_validate(content) do
    case Jason.decode(content) do
      {:ok, envelope} ->
        if expired?(envelope["expires_at"]) do
          {:error, :cache_expired}
        else
          {:ok, envelope["data"]}
        end

      {:error, _reason} ->
        {:error, :invalid_cache}
    end
  end

  defp existing_status(key, path, size) do
    base = %Status{key: key, exists: true, expired: true, size_bytes: size}

    with {:ok, content} <- File.read(path),
         {:ok, envelope} <- Jason.decode(content) do
      %{
        base
        | expired: expired?(envelope["expires_at"]),
          cached_at: envelope["cached_at"],
          expires_at: envelope["expires_at"]
      }
    else
      _ -> base
    end
  end

  defp accumulate_stats(path, acc) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        expired = file_expired?(path)

        %{
          total_entries: acc.total_entries + 1,
          total_size_bytes: acc.total_size_bytes + size,
          expired_entries: acc.expired_entries + if(expired, do: 1, else: 0),
          valid_entries: acc.valid_entries + if(expired, do: 0, else: 1)
        }

      {:error, _reason} ->
        acc
    end
  end

  defp file_expired?(path) do
    with {:ok, content} <- File.read(path),
         {:ok, envelope} <- Jason.decode(content) do
      expired?(envelope["expires_at"])
    else
      _ -> true
    end
  end

  defp read_fresh(path, ttl) when is_number(ttl) and ttl > 0 do
    now = System.system_time(:second)

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- now - mtime < ttl,
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ -> :miss
    end
  end

  defp read_fresh(_path, _ttl), do: :miss

  defp fetch_and_store(fetch_fn, path) do
    case fetch_fn.() do
      {:ok, content} = ok when is_binary(content) ->
        _ = atomic_write(path, content)
        ok

      other ->
        other
    end
  end
end
