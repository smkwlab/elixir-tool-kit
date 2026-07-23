defmodule ToolKit.GitHub.Client do
  @moduledoc """
  GitHub REST API への薄い HTTP ラッパ(Req ベース)。

  各ツールが共通で使う endpoint ヘルパとエラー分類を提供する。
  orchestration とレスポンスの解釈(パース)はツール側の責務とし、
  本モジュールは HTTP 境界に徹する。

  ## 認証

  トークンは `:token_provider` オプションで注入する。省略時は
  GitHub CLI(`gh auth token`)から取得する(`gh_cli_token/0`)。

  ## オプション

  すべての関数が共通で受け取る:

    * `:token_provider` - `(-> {:ok, token} | {:error, reason})` 形式の関数。
      既定は `gh_cli_token/0`
    * `:base_url` - API のベース URL(既定 `"https://api.github.com"`)
    * `:receive_timeout` - 応答タイムアウト(ミリ秒、既定 30_000)
    * `:user_agent` - User-Agent ヘッダ(既定 `"elixir-tool-kit"`)
    * `:req_options` - Req にそのまま渡す追加オプション
      (テストでの `plug: {Req.Test, Name}` 差し替えなど)

  ## 戻り値とエラー分類

    * `{:ok, body}` - 2xx。ボディは Req がデコードした値
    * `{:error, :not_found}` - 404
    * `{:error, :unauthorized}` - 401 / 403(トークンの権限不足)。
      404 と区別して返すため、呼び出し側は「存在しない」と
      「権限がない」を混同せずに扱える
    * `{:error, {:http_error, status, message}}` - その他の 4xx / 5xx
    * `{:error, {:request_failed, reason}}` - 通信自体の失敗
    * `{:error, {:token_error, reason}}` - トークン取得の失敗
  """

  @default_base_url "https://api.github.com"
  @default_receive_timeout 30_000
  @default_user_agent "elixir-tool-kit"

  @type token_provider :: (-> {:ok, String.t()} | {:error, term()})

  @type error ::
          :not_found
          | :unauthorized
          | {:http_error, non_neg_integer(), String.t()}
          | {:request_failed, term()}
          | {:token_error, term()}

  @type result :: {:ok, term()} | {:error, error()}

  @type method :: :get | :post | :put | :patch | :delete

  @typedoc "Req のレスポンス相当(`Req.Response.t()` を含む)"
  @type http_response :: %{
          :status => non_neg_integer(),
          :body => term(),
          optional(atom()) => term()
        }

  # ---------------------------------------------------------------
  # 汎用リクエスト
  # ---------------------------------------------------------------

  @doc """
  GET リクエストを送る。
  """
  @spec get(String.t(), keyword()) :: result()
  def get(path, opts \\ []), do: request(:get, path, opts)

  @doc """
  POST リクエストを送る(`body` は JSON として送信)。
  """
  @spec post(String.t(), term(), keyword()) :: result()
  def post(path, body, opts \\ []), do: request(:post, path, Keyword.put(opts, :json, body))

  @doc """
  PUT リクエストを送る(`body` は JSON として送信)。
  """
  @spec put(String.t(), term(), keyword()) :: result()
  def put(path, body, opts \\ []), do: request(:put, path, Keyword.put(opts, :json, body))

  @doc """
  PATCH リクエストを送る(`body` は JSON として送信)。
  """
  @spec patch(String.t(), term(), keyword()) :: result()
  def patch(path, body, opts \\ []), do: request(:patch, path, Keyword.put(opts, :json, body))

  @doc """
  任意のメソッドでリクエストを送る。

  `path` は `"/repos/owner/repo"` のようなベース URL からの相対パス。
  クエリパラメータは `:params`(keyword)で渡す。
  """
  @spec request(method(), String.t(), keyword()) :: result()
  def request(method, path, opts \\ []) do
    case fetch_token(opts) do
      {:ok, token} ->
        method
        |> run_request(path, token, opts)
        |> classify_response()

      {:error, reason} ->
        {:error, {:token_error, reason}}
    end
  end

  # ---------------------------------------------------------------
  # contents API
  # ---------------------------------------------------------------

  @doc """
  ファイル内容を取得する(contents API)。

  レスポンスには base64 の `"content"` と楽観ロック用の `"sha"` が
  含まれる。テキストが必要なら `decode_content/1` か `get_file_text/3`
  を使う。`:ref` オプションでブランチ・タグ・SHA を指定できる。
  """
  @spec get_file_contents(String.t(), String.t(), keyword()) :: result()
  def get_file_contents(repo, file_path, opts \\ []) do
    {ref, opts} = Keyword.pop(opts, :ref)
    get("/repos/#{repo}/contents/#{file_path}", put_params(opts, ref: ref))
  end

  @doc """
  ファイルを作成・更新する(contents API)。

  `content` は生テキストを受け取り、内部で base64 エンコードする。
  更新時は `:sha` オプションに取得済みの blob SHA を渡すこと
  (楽観ロック。競合すると 409 が返る)。新規作成時は `:sha` を
  省略する。`:branch` オプションでコミット先ブランチを指定できる。
  """
  @spec put_file_contents(String.t(), String.t(), String.t(), String.t(), keyword()) :: result()
  def put_file_contents(repo, file_path, content, commit_message, opts \\ []) do
    {sha, opts} = Keyword.pop(opts, :sha)
    {branch, opts} = Keyword.pop(opts, :branch)

    body =
      %{message: commit_message, content: Base.encode64(content)}
      |> put_present(:sha, sha)
      |> put_present(:branch, branch)

    put("/repos/#{repo}/contents/#{file_path}", body, opts)
  end

  @doc """
  ファイルを取得してテキストにデコードするところまで行う。

  blob SHA も必要な場合(更新の前段)は `get_file_contents/3` を使い、
  `decode_content/1` と組み合わせること。
  """
  @spec get_file_text(String.t(), String.t(), keyword()) :: result()
  def get_file_text(repo, file_path, opts \\ []) do
    with {:ok, body} <- get_file_contents(repo, file_path, opts) do
      decode_content(body)
    end
  end

  @doc """
  contents API のレスポンスからテキストを取り出す(純関数)。

  `"content"` は 60 桁ごとに改行が入った base64 で返るため、
  改行を除去してからデコードする。

  ## Examples

      iex> ToolKit.GitHub.Client.decode_content(%{"content" => "aGVsbG8=", "encoding" => "base64"})
      {:ok, "hello"}

  """
  @spec decode_content(term()) :: {:ok, String.t()} | {:error, :invalid_content}
  def decode_content(%{"content" => content, "encoding" => "base64"}) when is_binary(content) do
    decoded =
      content
      |> String.replace(["\n", "\r"], "")
      |> Base.decode64()

    case decoded do
      {:ok, text} -> {:ok, text}
      :error -> {:error, :invalid_content}
    end
  end

  def decode_content(_body), do: {:error, :invalid_content}

  # ---------------------------------------------------------------
  # repo / commits / pulls / issues
  # ---------------------------------------------------------------

  @doc """
  リポジトリ情報を取得する。
  """
  @spec get_repository(String.t(), keyword()) :: result()
  def get_repository(repo, opts \\ []), do: get("/repos/#{repo}", opts)

  @doc """
  ブランチ一覧を取得する。`:per_page` を指定できる。
  """
  @spec list_branches(String.t(), keyword()) :: result()
  def list_branches(repo, opts \\ []) do
    {params, opts} = Keyword.split(opts, [:per_page])
    get("/repos/#{repo}/branches", put_params(opts, params))
  end

  @doc """
  コミット一覧を取得する。`:since`(ISO8601)・`:author`・`:per_page`
  を指定できる。
  """
  @spec list_commits(String.t(), keyword()) :: result()
  def list_commits(repo, opts \\ []) do
    {params, opts} = Keyword.split(opts, [:since, :author, :per_page])
    get("/repos/#{repo}/commits", put_params(opts, params))
  end

  @doc """
  プルリクエスト一覧を取得する。`:state`(open / closed / all)・
  `:per_page` を指定できる。
  """
  @spec list_pull_requests(String.t(), keyword()) :: result()
  def list_pull_requests(repo, opts \\ []) do
    {params, opts} = Keyword.split(opts, [:state, :per_page])
    get("/repos/#{repo}/pulls", put_params(opts, params))
  end

  @doc """
  プルリクエストのレビュー一覧を取得する。`:per_page` を指定できる。
  """
  @spec list_pull_request_reviews(String.t(), pos_integer(), keyword()) :: result()
  def list_pull_request_reviews(repo, pr_number, opts \\ []) do
    {params, opts} = Keyword.split(opts, [:per_page])
    get("/repos/#{repo}/pulls/#{pr_number}/reviews", put_params(opts, params))
  end

  @doc """
  プルリクエストの保留中レビューリクエスト(依頼済みレビュアー)を取得する。
  """
  @spec get_requested_reviewers(String.t(), pos_integer(), keyword()) :: result()
  def get_requested_reviewers(repo, pr_number, opts \\ []) do
    get("/repos/#{repo}/pulls/#{pr_number}/requested_reviewers", opts)
  end

  @doc """
  Issue / プルリクエストにコメントを投稿する。
  """
  @spec create_issue_comment(String.t(), pos_integer(), String.t(), keyword()) :: result()
  def create_issue_comment(repo, issue_number, comment_body, opts \\ []) do
    post("/repos/#{repo}/issues/#{issue_number}/comments", %{body: comment_body}, opts)
  end

  @doc """
  プルリクエストをクローズする(archive 前の整理などに使う)。
  """
  @spec close_pull_request(String.t(), pos_integer(), keyword()) :: result()
  def close_pull_request(repo, pr_number, opts \\ []) do
    patch("/repos/#{repo}/pulls/#{pr_number}", %{state: "closed"}, opts)
  end

  @doc """
  リポジトリを archive する。
  """
  @spec archive_repository(String.t(), keyword()) :: result()
  def archive_repository(repo, opts \\ []) do
    patch("/repos/#{repo}", %{archived: true}, opts)
  end

  # ---------------------------------------------------------------
  # エラー分類
  # ---------------------------------------------------------------

  @doc """
  Req の結果をエラー分類済みの `t:result/0` に写す(純関数)。
  """
  @spec classify_response({:ok, http_response()} | {:error, term()}) :: result()
  def classify_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  def classify_response({:ok, %{status: 404}}), do: {:error, :not_found}

  def classify_response({:ok, %{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  def classify_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, extract_error_message(body, status)}}

  def classify_response({:error, reason}), do: {:error, {:request_failed, reason}}

  @doc """
  エラーが 404(Not Found)かを判定する。

  分類済みの reason(`:not_found`)と `{:error, reason}` タプルの
  どちらも受け取れる。
  """
  @spec not_found_error?(term()) :: boolean()
  def not_found_error?(:not_found), do: true
  def not_found_error?({:error, :not_found}), do: true
  def not_found_error?(_other), do: false

  @doc """
  エラーが 401 / 403(認証・権限不足)かを判定する。

  分類済みの reason(`:unauthorized`)と `{:error, reason}` タプルの
  どちらも受け取れる。
  """
  @spec unauthorized_error?(term()) :: boolean()
  def unauthorized_error?(:unauthorized), do: true
  def unauthorized_error?({:error, :unauthorized}), do: true
  def unauthorized_error?(_other), do: false

  # ---------------------------------------------------------------
  # トークン取得・URL 構築
  # ---------------------------------------------------------------

  @doc """
  既定のトークンプロバイダ。GitHub CLI(`gh auth token`)から取得する。

  外部コマンド実行のためテストカバレッジの対象外。
  """
  @spec gh_cli_token() :: {:ok, String.t()} | {:error, String.t()}
  def gh_cli_token do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} -> {:ok, String.trim(token)}
      {_output, _exit_code} -> {:error, "GitHub CLI authentication failed. Run 'gh auth login'"}
    end
  rescue
    ErlangError -> {:error, "GitHub CLI (gh) not found in PATH"}
  end

  @doc """
  ベース URL とパスをスラッシュ 1 個で結合する(純関数)。
  """
  @spec build_url(String.t(), String.t()) :: String.t()
  def build_url(base_url, path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  # ---------------------------------------------------------------
  # プライベート関数
  # ---------------------------------------------------------------

  defp fetch_token(opts) do
    provider = Keyword.get(opts, :token_provider, &gh_cli_token/0)
    provider.()
  end

  defp run_request(method, path, token, opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    req_opts =
      [
        method: method,
        url: build_url(base_url, path),
        headers: build_headers(token, opts),
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
        retry: false
      ]
      |> put_present(:params, opts[:params])
      |> put_present(:json, opts[:json])
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    Req.request(req_opts)
  end

  defp build_headers(token, opts) do
    [
      {"accept", "application/vnd.github.v3+json"},
      {"authorization", "Bearer " <> token},
      {"user-agent", Keyword.get(opts, :user_agent, @default_user_agent)}
    ]
  end

  defp extract_error_message(%{"message" => message}, _status), do: message
  defp extract_error_message(body, status) when is_binary(body), do: "#{status} - #{body}"
  defp extract_error_message(_body, status), do: "HTTP #{status}"

  # クエリパラメータ(nil の値は落とす)を opts の :params に載せる
  defp put_params(opts, params) do
    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> opts
      present -> Keyword.put(opts, :params, present)
    end
  end

  defp put_present(map, _key, nil) when is_map(map), do: map
  defp put_present(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp put_present(keyword, _key, nil) when is_list(keyword), do: keyword

  defp put_present(keyword, key, value) when is_list(keyword),
    do: Keyword.put(keyword, key, value)
end
