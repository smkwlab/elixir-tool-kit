defmodule ToolKit.GitHub.ClientGhCliTest do
  # PATH 環境変数を書き換えるテストを含むため、他のテストと並列実行しない
  use ExUnit.Case, async: false

  alias ToolKit.GitHub.Client

  describe "gh_cli_token/0(既定プロバイダ)" do
    # 環境依存(gh の有無・認証状態)のため、戻り値の形だけを検証する
    test "認証状態にかかわらず {:ok, token} か {:error, message} を返す" do
      case Client.gh_cli_token() do
        {:ok, token} -> assert is_binary(token) and token != ""
        {:error, message} -> assert is_binary(message)
      end
    end

    test "gh が見つからない場合はエラーメッセージを返す" do
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "")
        assert {:error, message} = Client.gh_cli_token()
        assert message =~ "gh"
      after
        System.put_env("PATH", original_path)
      end
    end
  end
end
