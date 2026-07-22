defmodule ToolKit do
  @moduledoc """
  smkwlab の Elixir CLI ツール(registry-manager / thesis-monitor /
  ecosystem-manager)が共有する基盤ライブラリ。

  機能は `ToolKit.*` 名前空間のモジュールとして提供する。
  """

  @version Mix.Project.config()[:version]

  @doc """
  ライブラリのバージョン文字列を返す。

  ## Examples

      iex> is_binary(ToolKit.version())
      true

  """
  @spec version() :: String.t()
  def version, do: @version
end
