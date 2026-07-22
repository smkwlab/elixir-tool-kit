defmodule ToolKit.CLI.Parser do
  @moduledoc """
  spec 駆動の引数パース。

  strict パース(未知オプションはエラー)、`--help` / `<command> --help` の
  短絡、コマンド別オプション検証・enum 検証までを行い、コマンドの実行内容には
  関与しない。位置引数の解釈とエイリアスごとの argv 変換(例: `cache-status` →
  `cache status`)はツール側の責務。
  """

  alias ToolKit.CLI.Spec

  @typedoc """
  パース結果。

  - `:help` — グローバル help を表示する
  - `{:help_command, name}` — 正準コマンド名の help を表示する
  - `{:error, message}` — パース・検証エラー
  - `{:command, invoked, argv, opts}` — 検証済みコマンド。`invoked` は入力された
    ままの名前(エイリアスの可能性あり)。未知のコマンドもそのまま通す
    (dispatch 側が :help に落とす)
  """
  @type result ::
          :help
          | {:help_command, String.t()}
          | {:error, String.t()}
          | {:command, String.t(), [String.t()], keyword()}

  @doc "引数リストを spec に基づいてパースする"
  @spec parse(Spec.t(), [String.t()]) :: result()
  def parse(%Spec{} = spec, args) do
    {opts, argv, invalid} =
      OptionParser.parse(args, strict: Spec.strict_switches(spec), aliases: Spec.aliases(spec))

    cond do
      invalid != [] ->
        {:error, "不明なオプション: #{Enum.map_join(invalid, ", ", fn {name, _} -> name end)}"}

      opts[:help] ->
        parse_help_target(spec, argv)

      true ->
        parse_command(spec, argv, opts)
    end
  end

  # `<command> --help` はコマンド単体の help に落とす
  defp parse_help_target(spec, [first | _]) do
    case Spec.find_command(spec, first) do
      nil -> :help
      command -> {:help_command, command.name}
    end
  end

  defp parse_help_target(_spec, _), do: :help

  defp parse_command(_spec, [], _opts), do: :help

  defp parse_command(spec, [first | rest], opts) do
    case Spec.validate_opts(spec, first, opts) do
      :ok -> {:command, first, rest, opts}
      {:error, _} = error -> error
    end
  end
end
