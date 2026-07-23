defmodule ToolKit.CacheTest do
  use ExUnit.Case, async: true

  alias ToolKit.Cache
  alias ToolKit.Cache.Status

  # 呼び出しを self() へのメッセージで数える fetch 関数
  defp counting_fetch(result) do
    fn ->
      send(self(), :fetched)
      result
    end
  end

  describe "cache_path/2" do
    test "joins cache_dir / category / key with .json extension" do
      assert Cache.cache_path("repo", cache_dir: "/c", category: "activity") ==
               "/c/activity/repo.json"
    end

    test "defaults the category" do
      assert Cache.cache_path("repo", cache_dir: "/c") == "/c/default/repo.json"
    end

    test "sanitizes keys into flat file names" do
      assert Cache.cache_path("owner/repo name", cache_dir: "/c") ==
               "/c/default/owner_repo_name.json"
    end
  end

  describe "put/3 and get/2" do
    @tag :tmp_dir
    test "get returns the data stored by put", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]

      assert Cache.put("repo", %{"stars" => 3}, opts) == :ok
      assert Cache.get("repo", opts) == {:ok, %{"stars" => 3}}
    end

    @tag :tmp_dir
    test "get misses when nothing was stored", %{tmp_dir: tmp_dir} do
      assert Cache.get("repo", cache_dir: tmp_dir) == {:error, :cache_miss}
    end

    @tag :tmp_dir
    test "get reports an expired entry", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]

      assert Cache.put("repo", %{"stars" => 3}, Keyword.put(opts, :ttl, -1)) == :ok
      assert Cache.get("repo", opts) == {:error, :cache_expired}
    end

    @tag :tmp_dir
    test "get reports a corrupted entry", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]
      path = Cache.cache_path("repo", opts)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")

      assert Cache.get("repo", opts) == {:error, :invalid_cache}
    end

    @tag :tmp_dir
    test "categories are isolated", %{tmp_dir: tmp_dir} do
      assert Cache.put("repo", %{"a" => 1}, cache_dir: tmp_dir, category: "activity") == :ok

      assert Cache.get("repo", cache_dir: tmp_dir, category: "pr-status") ==
               {:error, :cache_miss}
    end

    @tag :tmp_dir
    test "put writes a JSON envelope with metadata and leaves no temp files",
         %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, category: "activity"]

      assert Cache.put("repo", %{"a" => 1}, opts) == :ok

      envelope = Cache.cache_path("repo", opts) |> File.read!() |> Jason.decode!()
      assert envelope["key"] == "repo"
      assert envelope["data"] == %{"a" => 1}
      assert {:ok, _, _} = DateTime.from_iso8601(envelope["cached_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(envelope["expires_at"])

      assert File.ls!(Path.join(tmp_dir, "activity")) == ["repo.json"]
    end

    @tag :tmp_dir
    test "put reports unencodable data without raising", %{tmp_dir: tmp_dir} do
      assert {:error, {:json_encode_failed, _}} =
               Cache.put("repo", %{"pid" => self()}, cache_dir: tmp_dir)
    end

    @tag :tmp_dir
    test "put reports write failures without raising", %{tmp_dir: tmp_dir} do
      not_a_dir = Path.join(tmp_dir, "not_a_dir")
      File.write!(not_a_dir, "x")

      assert {:error, {:write_failed, _}} =
               Cache.put("repo", %{"a" => 1}, cache_dir: not_a_dir)
    end
  end

  describe "delete/2 and refresh/2" do
    @tag :tmp_dir
    test "delete removes the entry", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]

      assert Cache.put("repo", %{"a" => 1}, opts) == :ok
      assert Cache.delete("repo", opts) == :ok
      assert Cache.get("repo", opts) == {:error, :cache_miss}
    end

    @tag :tmp_dir
    test "delete is a no-op for a missing entry", %{tmp_dir: tmp_dir} do
      assert Cache.delete("repo", cache_dir: tmp_dir) == :ok
    end

    @tag :tmp_dir
    test "refresh forces a re-fetch on next access", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]

      assert Cache.put("repo", %{"a" => 1}, opts) == :ok
      assert Cache.refresh("repo", opts) == :ok
      assert Cache.get("repo", opts) == {:error, :cache_miss}
    end
  end

  describe "clear/1" do
    @tag :tmp_dir
    test "clears only its own category", %{tmp_dir: tmp_dir} do
      assert Cache.put("repo", %{"a" => 1}, cache_dir: tmp_dir, category: "activity") == :ok
      assert Cache.put("repo", %{"b" => 2}, cache_dir: tmp_dir, category: "pr-status") == :ok

      assert Cache.clear(cache_dir: tmp_dir, category: "activity") == :ok

      assert Cache.get("repo", cache_dir: tmp_dir, category: "activity") ==
               {:error, :cache_miss}

      assert Cache.get("repo", cache_dir: tmp_dir, category: "pr-status") == {:ok, %{"b" => 2}}
    end

    @tag :tmp_dir
    test "is a no-op when the category directory does not exist", %{tmp_dir: tmp_dir} do
      assert Cache.clear(cache_dir: tmp_dir, category: "missing") == :ok
    end
  end

  describe "status/2" do
    @tag :tmp_dir
    test "reports a missing entry", %{tmp_dir: tmp_dir} do
      assert Cache.status("repo", cache_dir: tmp_dir) == %Status{
               key: "repo",
               exists: false,
               expired: false,
               cached_at: nil,
               expires_at: nil,
               size_bytes: 0
             }
    end

    @tag :tmp_dir
    test "reports a valid entry", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]
      assert Cache.put("repo", %{"a" => 1}, opts) == :ok

      status = Cache.status("repo", opts)
      assert %Status{key: "repo", exists: true, expired: false} = status
      assert {:ok, _, _} = DateTime.from_iso8601(status.cached_at)
      assert {:ok, _, _} = DateTime.from_iso8601(status.expires_at)
      assert status.size_bytes > 0
    end

    @tag :tmp_dir
    test "reports an expired entry", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]
      assert Cache.put("repo", %{"a" => 1}, Keyword.put(opts, :ttl, -1)) == :ok

      assert %Status{exists: true, expired: true} = Cache.status("repo", opts)
    end

    @tag :tmp_dir
    test "reports a corrupted entry as expired", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]
      path = Cache.cache_path("repo", opts)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")

      status = Cache.status("repo", opts)
      assert %Status{exists: true, expired: true, cached_at: nil, expires_at: nil} = status
      assert status.size_bytes > 0
    end
  end

  describe "stats/1" do
    @empty %{total_entries: 0, total_size_bytes: 0, expired_entries: 0, valid_entries: 0}

    @tag :tmp_dir
    test "returns zeros when the category directory does not exist", %{tmp_dir: tmp_dir} do
      assert Cache.stats(cache_dir: tmp_dir, category: "missing") == @empty
    end

    @tag :tmp_dir
    test "counts valid and expired entries, ignoring non-JSON files", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir]

      assert Cache.put("fresh-1", %{"a" => 1}, opts) == :ok
      assert Cache.put("fresh-2", %{"b" => 2}, opts) == :ok
      assert Cache.put("stale", %{"c" => 3}, Keyword.put(opts, :ttl, -1)) == :ok
      File.write!(Path.join([tmp_dir, "default", "raw-binary"]), "raw")

      stats = Cache.stats(opts)
      assert stats.total_entries == 3
      assert stats.valid_entries == 2
      assert stats.expired_entries == 1
      assert stats.total_size_bytes > 0
    end
  end

  describe "expired?/1" do
    test "nil is expired" do
      assert Cache.expired?(nil)
    end

    test "an unparsable timestamp is expired" do
      assert Cache.expired?("not-a-date")
    end

    test "a past timestamp is expired" do
      assert Cache.expired?("2020-01-01T00:00:00Z")
    end

    test "a future timestamp is not expired" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      refute Cache.expired?(future)
    end
  end

  describe "get_or_fetch/3" do
    @tag :tmp_dir
    test "fetches on miss and serves the cached copy afterwards", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, ttl: 60]

      assert Cache.get_or_fetch("key", counting_fetch({:ok, "body"}), opts) == {:ok, "body"}
      assert_received :fetched

      assert Cache.get_or_fetch("key", counting_fetch({:ok, "other"}), opts) == {:ok, "body"}
      refute_received :fetched
    end

    @tag :tmp_dir
    test "re-fetches once the file mtime falls outside the TTL", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, ttl: 60]

      assert Cache.get_or_fetch("key", counting_fetch({:ok, "old"}), opts) == {:ok, "old"}
      File.touch!(Path.join([tmp_dir, "default", "key"]), System.os_time(:second) - 120)

      assert Cache.get_or_fetch("key", counting_fetch({:ok, "new"}), opts) == {:ok, "new"}
      assert_received :fetched
      assert_received :fetched
    end

    @tag :tmp_dir
    test "ttl <= 0 always misses (--no-cache)", %{tmp_dir: tmp_dir} do
      for ttl <- [0, -1] do
        opts = [cache_dir: tmp_dir, category: "ttl#{ttl}", ttl: ttl]

        assert Cache.get_or_fetch("key", counting_fetch({:ok, "a"}), opts) == {:ok, "a"}
        assert Cache.get_or_fetch("key", counting_fetch({:ok, "b"}), opts) == {:ok, "b"}
        assert_received :fetched
        assert_received :fetched
      end
    end

    @tag :tmp_dir
    test "passes fetch errors through without caching them", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, ttl: 60]

      assert Cache.get_or_fetch("key", fn -> {:error, :boom} end, opts) == {:error, :boom}
      refute File.exists?(Path.join([tmp_dir, "default", "key"]))

      assert Cache.get_or_fetch("key", counting_fetch({:ok, "body"}), opts) == {:ok, "body"}
      assert_received :fetched
    end

    @tag :tmp_dir
    test "returns non-binary :ok results without caching them", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, ttl: 60]

      assert Cache.get_or_fetch("key", fn -> {:ok, %{"a" => 1}} end, opts) == {:ok, %{"a" => 1}}
      refute File.exists?(Path.join([tmp_dir, "default", "key"]))
    end

    @tag :tmp_dir
    test "writes atomically: only the final file remains", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, ttl: 60]

      assert Cache.get_or_fetch("key", counting_fetch({:ok, "body"}), opts) == {:ok, "body"}

      assert File.ls!(Path.join(tmp_dir, "default")) == ["key"]
      assert File.read!(Path.join([tmp_dir, "default", "key"])) == "body"
    end

    @tag :tmp_dir
    test "sanitizes keys into flat file names", %{tmp_dir: tmp_dir} do
      opts = [cache_dir: tmp_dir, ttl: 60]

      assert Cache.get_or_fetch("owner/repo", counting_fetch({:ok, "body"}), opts) ==
               {:ok, "body"}

      assert File.ls!(Path.join(tmp_dir, "default")) == ["owner_repo"]
    end

    @tag :tmp_dir
    test "still returns the fetched value when the cache is unwritable", %{tmp_dir: tmp_dir} do
      not_a_dir = Path.join(tmp_dir, "not_a_dir")
      File.write!(not_a_dir, "x")
      opts = [cache_dir: not_a_dir, ttl: 60]

      assert Cache.get_or_fetch("key", counting_fetch({:ok, "body"}), opts) == {:ok, "body"}
    end
  end
end
