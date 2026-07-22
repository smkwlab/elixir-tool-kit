defmodule ToolKit.CLI.Exit do
  @moduledoc """
  exit code の規律(成功 0 / エラー 1)。

  通常は `System.halt/1` で終了する。テストからは終了せずに検証できるよう、
  ツールのアプリケーション env で `test_mode: true` が設定されている場合は
  `throw({:cli_test_exit, code})` に切り替わる。
  """

  @doc """
  exit code つきで終了する。

  `app` はツールのアプリケーション名(例: `:registry_manager`)。
  `Application.get_env(app, :test_mode)` が true のときは halt せず
  `{:cli_test_exit, code}` を throw する。
  """
  @spec exit_with_code(atom(), non_neg_integer()) :: no_return()
  def exit_with_code(app, code) do
    if Application.get_env(app, :test_mode, false) do
      throw({:cli_test_exit, code})
    else
      System.halt(code)
    end
  end
end
