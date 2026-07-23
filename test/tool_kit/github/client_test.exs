defmodule ToolKit.GitHub.ClientTest do
  use ExUnit.Case, async: true

  alias ToolKit.GitHub.Client

  doctest ToolKit.GitHub.Client

  @stub ToolKit.GitHub.ClientStub

  # 実 HTTP は呼ばず、Req.Test の Plug スタブへ差し替える共通オプション
  defp opts(extra \\ []) do
    Keyword.merge(
      [
        token_provider: fn -> {:ok, "test-token"} end,
        req_options: [plug: {Req.Test, @stub}]
      ],
      extra
    )
  end

  defp stub_capture(test_pid, response_body) do
    Req.Test.stub(@stub, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)

      send(
        test_pid,
        {:request,
         %{method: conn.method, path: conn.request_path, query: conn.query_params, body: raw_body}}
      )

      Req.Test.json(conn, response_body)
    end)
  end

  describe "request/3 の共通挙動" do
    test "Bearer トークンと GitHub API 用ヘッダを送る" do
      Req.Test.stub(@stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
        assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
        assert Plug.Conn.get_req_header(conn, "x-github-api-version") == ["2022-11-28"]
        assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
        assert user_agent =~ "elixir-tool-kit"
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{"ok" => true}} = Client.get("/repos/smkwlab/demo", opts())
    end

    test ":user_agent オプションで User-Agent を差し替えられる" do
      Req.Test.stub(@stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["my-tool/1.0"]
        Req.Test.json(conn, %{})
      end)

      assert {:ok, _} = Client.get("/user", opts(user_agent: "my-tool/1.0"))
    end

    test "token_provider の失敗は {:token_error, reason} に包んで返す" do
      failing = fn -> {:error, :no_token} end

      assert {:error, {:token_error, :no_token}} =
               Client.get("/repos/smkwlab/demo", opts(token_provider: failing))
    end

    test "post/2 は JSON ボディを送る" do
      stub_capture(self(), %{"id" => 1})

      assert {:ok, %{"id" => 1}} =
               Client.post("/repos/smkwlab/demo/labels", %{name: "bug"}, opts())

      assert_received {:request, request}
      assert request.method == "POST"
      assert Jason.decode!(request.body) == %{"name" => "bug"}
    end

    test "put/2 と patch/2 は対応する HTTP メソッドを使う" do
      stub_capture(self(), %{})
      assert {:ok, _} = Client.put("/x", %{a: 1}, opts())
      assert_received {:request, %{method: "PUT"}}

      stub_capture(self(), %{})
      assert {:ok, _} = Client.patch("/x", %{a: 1}, opts())
      assert_received {:request, %{method: "PATCH"}}
    end

    test "通信自体の失敗は {:request_failed, reason} を返す" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:request_failed, %Req.TransportError{reason: :timeout}}} =
               Client.get("/repos/smkwlab/demo", opts())
    end
  end

  describe "エラー分類(HTTP 経由)" do
    test "404 は {:error, :not_found}" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, :not_found} = Client.get("/repos/smkwlab/none", opts())
    end

    test "401 と 403 は {:error, :unauthorized}" do
      for status <- [401, 403] do
        Req.Test.stub(@stub, fn conn ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => "Bad credentials"})
        end)

        assert {:error, :unauthorized} = Client.get("/repos/smkwlab/private", opts())
      end
    end

    test "その他のエラーは {:http_error, status, message}" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      assert {:error, {:http_error, 422, "Validation Failed"}} =
               Client.get("/repos/smkwlab/demo", opts())
    end
  end

  describe "classify_response/1(純関数)" do
    test "2xx はボディをそのまま返す" do
      assert Client.classify_response({:ok, %{status: 200, body: %{"a" => 1}}}) ==
               {:ok, %{"a" => 1}}

      assert Client.classify_response({:ok, %{status: 201, body: nil}}) == {:ok, nil}
    end

    test "404 / 401 / 403 を分類する" do
      assert Client.classify_response({:ok, %{status: 404, body: %{}}}) == {:error, :not_found}
      assert Client.classify_response({:ok, %{status: 401, body: %{}}}) == {:error, :unauthorized}
      assert Client.classify_response({:ok, %{status: 403, body: %{}}}) == {:error, :unauthorized}
    end

    test "エラーメッセージはボディ形式に応じて抽出する" do
      assert Client.classify_response({:ok, %{status: 500, body: %{"message" => "boom"}}}) ==
               {:error, {:http_error, 500, "boom"}}

      assert Client.classify_response({:ok, %{status: 500, body: "internal error"}}) ==
               {:error, {:http_error, 500, "500 - internal error"}}

      assert Client.classify_response({:ok, %{status: 502, body: %{"other" => true}}}) ==
               {:error, {:http_error, 502, "HTTP 502"}}
    end

    test "Req のエラーは {:request_failed, reason} に包む" do
      assert Client.classify_response({:error, :nxdomain}) ==
               {:error, {:request_failed, :nxdomain}}
    end
  end

  describe "build_url/2(純関数)" do
    test "base_url と path をスラッシュ 1 個で結合する" do
      assert Client.build_url("https://api.github.com", "/repos/a/b") ==
               "https://api.github.com/repos/a/b"

      assert Client.build_url("https://api.github.com/", "repos/a/b") ==
               "https://api.github.com/repos/a/b"

      assert Client.build_url("https://ghe.example.com/api/v3/", "/repos/a/b") ==
               "https://ghe.example.com/api/v3/repos/a/b"
    end
  end

  describe "contents ヘルパ" do
    test "get_file_contents/3 は contents API を GET する" do
      stub_capture(self(), %{"content" => "e30=", "encoding" => "base64", "sha" => "abc"})

      assert {:ok, %{"sha" => "abc"}} =
               Client.get_file_contents("smkwlab/repo", "data/registry.json", opts())

      assert_received {:request, request}
      assert request.method == "GET"
      assert request.path == "/repos/smkwlab/repo/contents/data/registry.json"
      assert request.query == %{}
    end

    test "get_file_contents/3 は :ref をクエリに載せる" do
      stub_capture(self(), %{})
      assert {:ok, _} = Client.get_file_contents("smkwlab/repo", "README.md", opts(ref: "main"))

      assert_received {:request, %{query: %{"ref" => "main"}}}
    end

    test "put_file_contents/5 は base64 化した内容と SHA を PUT する" do
      stub_capture(self(), %{"commit" => %{"sha" => "new"}})

      assert {:ok, _} =
               Client.put_file_contents(
                 "smkwlab/repo",
                 "data/registry.json",
                 ~s({"students": []}),
                 "chore: update registry",
                 opts(sha: "oldsha", branch: "main")
               )

      assert_received {:request, request}
      assert request.method == "PUT"
      assert request.path == "/repos/smkwlab/repo/contents/data/registry.json"

      body = Jason.decode!(request.body)
      assert body["message"] == "chore: update registry"
      assert body["sha"] == "oldsha"
      assert body["branch"] == "main"
      assert Base.decode64!(body["content"]) == ~s({"students": []})
    end

    test "put_file_contents/5 は SHA なし(新規作成)なら sha キーを送らない" do
      stub_capture(self(), %{})

      assert {:ok, _} =
               Client.put_file_contents("smkwlab/repo", "new.txt", "hello", "add file", opts())

      assert_received {:request, request}
      body = Jason.decode!(request.body)
      refute Map.has_key?(body, "sha")
      refute Map.has_key?(body, "branch")
    end

    test "get_file_text/3 は取得とデコードをまとめて行う" do
      encoded = Base.encode64("hello world")
      stub_capture(self(), %{"content" => encoded, "encoding" => "base64"})

      assert {:ok, "hello world"} = Client.get_file_text("smkwlab/repo", "hello.txt", opts())
    end

    test "get_file_text/3 は取得エラーをそのまま返す" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, :not_found} = Client.get_file_text("smkwlab/repo", "none.txt", opts())
    end
  end

  describe "decode_content/1(純関数)" do
    test "60 桁ごとの改行入り base64 をデコードする" do
      text = String.duplicate("あいうえお", 30)

      wrapped =
        text
        |> Base.encode64()
        |> String.codepoints()
        |> Enum.chunk_every(60)
        |> Enum.map_join("\n", &Enum.join/1)

      assert Client.decode_content(%{"content" => wrapped, "encoding" => "base64"}) == {:ok, text}
    end

    test "不正な base64 は {:error, :invalid_content}" do
      assert Client.decode_content(%{"content" => "%%%", "encoding" => "base64"}) ==
               {:error, :invalid_content}
    end

    test "想定外の形式は {:error, :invalid_content}" do
      assert Client.decode_content(%{"encoding" => "base64"}) == {:error, :invalid_content}

      assert Client.decode_content(%{"content" => "e30=", "encoding" => "utf-8"}) ==
               {:error, :invalid_content}

      assert Client.decode_content("not a map") == {:error, :invalid_content}
    end
  end

  describe "repo / commits / pulls ヘルパ" do
    test "get_repository/2 はリポジトリ情報を GET する" do
      stub_capture(self(), %{"full_name" => "smkwlab/repo"})

      assert {:ok, %{"full_name" => "smkwlab/repo"}} =
               Client.get_repository("smkwlab/repo", opts())

      assert_received {:request, %{method: "GET", path: "/repos/smkwlab/repo"}}
    end

    test "list_branches/2 はブランチ一覧を GET する" do
      stub_capture(self(), [%{"name" => "main"}])

      assert {:ok, [%{"name" => "main"}]} =
               Client.list_branches("smkwlab/repo", opts(per_page: 100))

      assert_received {:request, request}
      assert request.path == "/repos/smkwlab/repo/branches"
      assert request.query == %{"per_page" => "100"}
    end

    test "list_commits/2 は since / author / per_page をクエリに載せる" do
      stub_capture(self(), [])

      assert {:ok, []} =
               Client.list_commits(
                 "smkwlab/repo",
                 opts(since: "2026-07-01T00:00:00Z", author: "student", per_page: 10)
               )

      assert_received {:request, request}
      assert request.path == "/repos/smkwlab/repo/commits"

      assert request.query == %{
               "since" => "2026-07-01T00:00:00Z",
               "author" => "student",
               "per_page" => "10"
             }
    end

    test "list_commits/2 は nil のパラメータを送らない" do
      stub_capture(self(), [])
      assert {:ok, []} = Client.list_commits("smkwlab/repo", opts(author: nil, per_page: 1))

      assert_received {:request, %{query: %{"per_page" => "1"} = query}}
      refute Map.has_key?(query, "author")
    end

    test "ヘルパは呼び出し元の :params を保持したままマージする" do
      stub_capture(self(), [])

      assert {:ok, []} = Client.list_commits("smkwlab/repo", opts(per_page: 5, params: [page: 2]))

      assert_received {:request, %{query: %{"per_page" => "5", "page" => "2"}}}
    end

    test "list_pull_requests/2 は state / per_page をクエリに載せる" do
      stub_capture(self(), [])

      assert {:ok, []} =
               Client.list_pull_requests("smkwlab/repo", opts(state: "all", per_page: 100))

      assert_received {:request, request}
      assert request.path == "/repos/smkwlab/repo/pulls"
      assert request.query == %{"state" => "all", "per_page" => "100"}
    end

    test "list_pull_request_reviews/3 はレビュー一覧を GET する" do
      stub_capture(self(), [])
      assert {:ok, []} = Client.list_pull_request_reviews("smkwlab/repo", 12, opts(per_page: 100))

      assert_received {:request, request}
      assert request.path == "/repos/smkwlab/repo/pulls/12/reviews"
      assert request.query == %{"per_page" => "100"}
    end

    test "get_requested_reviewers/3 はレビューリクエストを GET する" do
      stub_capture(self(), %{"users" => []})
      assert {:ok, %{"users" => []}} = Client.get_requested_reviewers("smkwlab/repo", 12, opts())

      assert_received {:request, %{path: "/repos/smkwlab/repo/pulls/12/requested_reviewers"}}
    end

    test "create_issue_comment/4 はコメントを POST する" do
      stub_capture(self(), %{"id" => 1})

      assert {:ok, _} = Client.create_issue_comment("smkwlab/repo", 34, "対応しました", opts())

      assert_received {:request, request}
      assert request.method == "POST"
      assert request.path == "/repos/smkwlab/repo/issues/34/comments"
      assert Jason.decode!(request.body) == %{"body" => "対応しました"}
    end

    test "close_pull_request/3 は state: closed を PATCH する" do
      stub_capture(self(), %{"state" => "closed"})

      assert {:ok, _} = Client.close_pull_request("smkwlab/repo", 5, opts())

      assert_received {:request, request}
      assert request.method == "PATCH"
      assert request.path == "/repos/smkwlab/repo/pulls/5"
      assert Jason.decode!(request.body) == %{"state" => "closed"}
    end

    test "archive_repository/2 は archived: true を PATCH する" do
      stub_capture(self(), %{"archived" => true})

      assert {:ok, _} = Client.archive_repository("smkwlab/repo", opts())

      assert_received {:request, request}
      assert request.method == "PATCH"
      assert request.path == "/repos/smkwlab/repo"
      assert Jason.decode!(request.body) == %{"archived" => true}
    end
  end

  describe "エラー述語" do
    test "not_found_error?/1 は :not_found と {:error, :not_found} を真とする" do
      assert Client.not_found_error?(:not_found)
      assert Client.not_found_error?({:error, :not_found})
      refute Client.not_found_error?(:unauthorized)
      refute Client.not_found_error?({:error, {:http_error, 500, "boom"}})
      refute Client.not_found_error?("GitHub API error (404)")
    end

    test "unauthorized_error?/1 は :unauthorized と {:error, :unauthorized} を真とする" do
      assert Client.unauthorized_error?(:unauthorized)
      assert Client.unauthorized_error?({:error, :unauthorized})
      refute Client.unauthorized_error?(:not_found)
      refute Client.unauthorized_error?(nil)
    end
  end
end
