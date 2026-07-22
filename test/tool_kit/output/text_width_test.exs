defmodule ToolKit.Output.TextWidthTest do
  use ExUnit.Case, async: true
  doctest ToolKit.Output.TextWidth

  alias ToolKit.Output.TextWidth

  describe "display_width/1" do
    test "ASCII counts as 1 per character" do
      assert TextWidth.display_width("Hello") == 5
      assert TextWidth.display_width("") == 0
    end

    test "CJK, fullwidth symbols, and hangul count as 2" do
      assert TextWidth.display_width("こんにちは") == 10
      assert TextWidth.display_width("Hello世界") == 9
      # 全角記号（U+FF01 FULLWIDTH EXCLAMATION MARK）
      assert TextWidth.display_width("！") == 2
      # ハングル
      assert TextWidth.display_width("한") == 2
    end

    test "control characters count as 0" do
      assert TextWidth.display_width("\t") == 0
      assert TextWidth.display_width("a\tb") == 2
    end

    test "multi-codepoint graphemes count as 1" do
      # 結合文字による1グラフェム（e + combining acute accent）
      assert TextWidth.display_width("é") == 1
    end
  end

  describe "pad_trailing/2" do
    test "pads with spaces up to the display width" do
      assert TextWidth.pad_trailing("ab", 5) == "ab   "
      assert TextWidth.pad_trailing("あい", 6) == "あい  "
    end

    test "returns the string unchanged when already wide enough" do
      assert TextWidth.pad_trailing("abcdef", 4) == "abcdef"
      assert TextWidth.pad_trailing("あいう", 6) == "あいう"
    end
  end

  describe "truncate/2" do
    test "returns the string unchanged when it fits" do
      assert TextWidth.truncate("hello", 10) == "hello"
      assert TextWidth.truncate("あい", 4) == "あい"
    end

    test "truncates by display width and appends ellipsis" do
      assert TextWidth.truncate("hello world", 8) == "hello..."
      # 全角は 2 幅で数える（"..." の 3 幅を確保して切る）
      assert TextWidth.truncate("あいうえお", 8) == "あい..."
    end

    test "very small widths cut without ellipsis" do
      assert TextWidth.truncate("hello", 3) == "hel"
      assert TextWidth.truncate("hello", 2) == "he"
    end

    test "very small widths never exceed the budget for fullwidth characters" do
      assert TextWidth.truncate("あい", 3) == "あ"
      assert TextWidth.truncate("あい", 2) == "あ"
      assert TextWidth.truncate("あい", 1) == ""
    end
  end
end
