defmodule ToolKit.Output.TextWidth do
  @moduledoc """
  East Asian 文字を考慮した表示幅の計算。

  日本語環境での表示幅を正確に計算するため、CJK 文字、ひらがな、カタカナ、
  全角記号、ハングルを 2 文字幅として扱う。厳密な East Asian Width 準拠では
  なく、日本語環境での一般的な表示に最適化された簡易版。

  制限: 上記の範囲以外(絵文字、アラビア文字、ラテン拡張など)はすべて
  1 幅として扱うため、端末で 2 幅表示される絵文字などは正確に扱えない。
  """

  @doc """
  文字列の表示幅を計算する(全角文字を考慮)。

  ## Examples

      iex> ToolKit.Output.TextWidth.display_width("Hello")
      5

      iex> ToolKit.Output.TextWidth.display_width("こんにちは")
      10

      iex> ToolKit.Output.TextWidth.display_width("Hello世界")
      9

  """
  @spec display_width(String.t()) :: non_neg_integer()
  def display_width(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, width ->
      width + grapheme_display_width(grapheme)
    end)
  end

  @doc """
  表示幅ベースで末尾にスペースを詰める。

  すでに `target_width` 以上の幅がある場合はそのまま返す(切り詰めない)。

  ## Examples

      iex> ToolKit.Output.TextWidth.pad_trailing("あい", 6)
      "あい  "

  """
  @spec pad_trailing(String.t(), non_neg_integer()) :: String.t()
  def pad_trailing(string, target_width) do
    padding_needed = max(0, target_width - display_width(string))
    string <> String.duplicate(" ", padding_needed)
  end

  @doc """
  表示幅ベースで文字列を切り詰め、`...` を付ける。

  幅が収まっている場合はそのまま返す。`max_width` が 3 以下の場合は
  `...` を付けず先頭からの文字数で切る。

  ## Examples

      iex> ToolKit.Output.TextWidth.truncate("hello world", 8)
      "hello..."

      iex> ToolKit.Output.TextWidth.truncate("あいうえお", 8)
      "あい..."

  """
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(string, max_width) do
    if display_width(string) <= max_width do
      string
    else
      truncate_by_display_width(string, max_width)
    end
  end

  # "..." を置く余地がない幅では、表示幅ベースでそのまま切る
  defp truncate_by_display_width(string, max_width) when max_width <= 3 do
    take_by_display_width(string, max_width)
  end

  defp truncate_by_display_width(string, max_width) do
    # "..." の 3 幅分を確保して切る
    take_by_display_width(string, max_width - 3) <> "..."
  end

  defp take_by_display_width(string, budget) do
    {kept, _width} =
      string
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {acc, acc_width} ->
        new_width = acc_width + grapheme_display_width(grapheme)

        if new_width > budget do
          {:halt, {acc, acc_width}}
        else
          {:cont, {[grapheme | acc], new_width}}
        end
      end)

    kept |> Enum.reverse() |> Enum.join()
  end

  defp grapheme_display_width(grapheme) do
    case String.to_charlist(grapheme) do
      [codepoint] -> codepoint_display_width(codepoint)
      # 複数コードポイントの場合は 1 文字幅として扱う
      _ -> 1
    end
  end

  # 制御文字
  defp codepoint_display_width(codepoint) when codepoint <= 0x1F, do: 0
  # ASCII
  defp codepoint_display_width(codepoint) when codepoint <= 0x7F, do: 1
  # C1 制御文字（0x80-0x9F）
  defp codepoint_display_width(codepoint) when codepoint <= 0x9F, do: 0
  # CJK系全般
  defp codepoint_display_width(codepoint) when codepoint >= 0x3000 and codepoint <= 0x9FFF,
    do: 2

  # 全角記号
  defp codepoint_display_width(codepoint) when codepoint >= 0xFF00 and codepoint <= 0xFFEF,
    do: 2

  # ハングル
  defp codepoint_display_width(codepoint) when codepoint >= 0xAC00 and codepoint <= 0xD7AF,
    do: 2

  # その他デフォルト
  defp codepoint_display_width(_codepoint), do: 1
end
