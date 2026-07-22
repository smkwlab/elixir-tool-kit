defmodule ToolKit.Output.Table do
  @moduledoc """
  表示幅対応のプレーンテキストテーブル描画。

  文字列を返すだけで印字はしない(印字・色付け・テストモード出力は
  ツール側の責務)。全セルを列幅までパディングして `gap` で連結する。

  ## オプション

  - `:gap` — 列間の区切り文字列(デフォルト `"  "`)
  - `:min_widths` / `:max_widths` — 列 index → 幅の制約。`max_widths` を
    超えるセルは `...` 付きで切り詰められる
  """

  alias ToolKit.Output.TextWidth

  @type opts :: [
          gap: String.t(),
          min_widths: %{non_neg_integer() => pos_integer()},
          max_widths: %{non_neg_integer() => pos_integer()}
        ]

  @doc """
  ヘッダー行・セパレータ行・データ行からなるテーブル文字列を生成する。
  """
  @spec render([String.t()], [[String.t()]], opts()) :: String.t()
  def render(headers, rows, opts \\ []) do
    gap = Keyword.get(opts, :gap, "  ")
    widths = column_widths(headers, rows, opts)

    truncated_rows =
      Enum.map(rows, fn row ->
        row
        |> Enum.zip(widths)
        |> Enum.map(fn {cell, width} -> TextWidth.truncate(to_string(cell), width) end)
      end)

    lines =
      [format_row(headers, widths, gap), separator(widths, gap)] ++
        Enum.map(truncated_rows, &format_row(&1, widths, gap))

    Enum.join(lines, "\n")
  end

  @doc """
  各列の幅(ヘッダー・全行の表示幅の最大値)を計算する。

  `:min_widths` / `:max_widths` で列ごとの下限・上限を指定できる。
  """
  @spec column_widths([String.t()], [[String.t()]], opts()) :: [non_neg_integer()]
  def column_widths(headers, rows, opts \\ []) do
    min_widths = Keyword.get(opts, :min_widths, %{})
    max_widths = Keyword.get(opts, :max_widths, %{})

    initial = Enum.map(headers, &TextWidth.display_width(to_string(&1)))

    rows
    |> Enum.reduce(initial, fn row, acc ->
      row
      |> Enum.map(&TextWidth.display_width(to_string(&1)))
      |> then(&Enum.zip_with(acc, &1, fn a, b -> max(a, b) end))
    end)
    |> Enum.with_index()
    |> Enum.map(fn {width, index} ->
      constrained = max(width, Map.get(min_widths, index, 0))

      case Map.get(max_widths, index) do
        nil -> constrained
        max_width -> min(constrained, max_width)
      end
    end)
  end

  @doc "セルを列幅までパディングして gap で連結した 1 行を生成する"
  @spec format_row([String.t()], [non_neg_integer()], String.t()) :: String.t()
  def format_row(cells, widths, gap \\ "  ") do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join(gap, fn {cell, width} ->
      TextWidth.pad_trailing(to_string(cell), width)
    end)
  end

  @doc "列幅に合わせた `-` のセパレータ行を生成する"
  @spec separator([non_neg_integer()], String.t()) :: String.t()
  def separator(widths, gap \\ "  ") do
    Enum.map_join(widths, gap, &String.duplicate("-", &1))
  end
end
