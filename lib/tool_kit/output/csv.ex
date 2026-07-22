defmodule ToolKit.Output.CSV do
  @moduledoc """
  CSV フィールドのエスケープと行の生成(RFC 4180 準拠のクォート)。
  """

  @doc """
  フィールドをエスケープする。

  カンマ・二重引用符・改行を含む場合は全体を `"` で囲み、内部の `"` は
  `""` に重ねる。バイナリ以外の値は文字列化する(nil は空文字列)。

  ## Examples

      iex> ToolKit.Output.CSV.escape_field("a,b")
      "\\"a,b\\""

  """
  @spec escape_field(term()) :: String.t()
  def escape_field(nil), do: ""

  def escape_field(field) when is_binary(field) do
    if String.contains?(field, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end

  def escape_field(field), do: field |> to_string() |> escape_field()

  @doc """
  フィールドのリストから CSV 1 行を生成する(改行は含まない)。

  ## Examples

      iex> ToolKit.Output.CSV.line(["a", "b,c", 1])
      "a,\\"b,c\\",1"

  """
  @spec line([term()]) :: String.t()
  def line(fields) do
    Enum.map_join(fields, ",", &escape_field/1)
  end
end
