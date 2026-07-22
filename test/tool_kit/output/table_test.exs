defmodule ToolKit.Output.TableTest do
  use ExUnit.Case, async: true
  doctest ToolKit.Output.Table

  alias ToolKit.Output.Table

  describe "column_widths/2,3" do
    test "takes the max display width per column, headers included" do
      assert Table.column_widths(["ID", "Name"], [["a", "田中"], ["abc", "x"]]) == [3, 4]
    end

    test "applies per-column min/max constraints" do
      widths =
        Table.column_widths(["N", "Long"], [["a", "b"]],
          min_widths: %{0 => 4},
          max_widths: %{1 => 3}
        )

      assert widths == [4, 3]
    end
  end

  describe "render/3" do
    test "renders header, separator, and width-aligned rows (registry-manager style)" do
      rendered =
        Table.render(["ID", "Name"], [["a", "田中太郎"], ["abc", "x"]])

      # 全セルをパディングして gap "  " で連結する（最終列にも末尾スペースが付く）
      expected =
        Enum.join(
          [
            "ID   Name    ",
            "---  --------",
            "a    田中太郎",
            "abc  x       "
          ],
          "\n"
        )

      assert rendered == expected
    end

    test "gap option switches to single-space joints (thesis-monitor style)" do
      rendered = Table.render(["A", "B"], [["1", "2"]], gap: " ")

      assert rendered == """
             A B
             - -
             1 2\
             """
    end

    test "cells wider than max_widths are truncated with ellipsis" do
      rendered =
        Table.render(["Name"], [["あいうえお"]], max_widths: %{0 => 8})

      assert rendered =~ "あい..."
      refute rendered =~ "あいうえお"
    end

    test "truncated fullwidth cells are padded back to the column width" do
      # truncate("あいうえお", 6) は "あ..."（幅 5）になり、残り 1 幅がパディングされる
      rendered = Table.render(["Header"], [["あいうえお"]], max_widths: %{0 => 6})

      assert rendered == Enum.join(["Header", "------", "あ... "], "\n")
    end

    test "empty rows render header and separator only" do
      assert Table.render(["A"], []) == "A\n-"
    end
  end
end
