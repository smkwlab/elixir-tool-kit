defmodule ToolKit.Output.CSVTest do
  use ExUnit.Case, async: true
  doctest ToolKit.Output.CSV

  alias ToolKit.Output.CSV

  describe "escape_field/1" do
    test "plain fields pass through" do
      assert CSV.escape_field("hello") == "hello"
      assert CSV.escape_field("田中") == "田中"
    end

    test "fields with comma, quote, or newline are quoted" do
      assert CSV.escape_field("a,b") == "\"a,b\""
      assert CSV.escape_field("say \"hi\"") == "\"say \"\"hi\"\"\""
      assert CSV.escape_field("line1\nline2") == "\"line1\nline2\""
    end

    test "non-binary values are stringified" do
      assert CSV.escape_field(42) == "42"
      assert CSV.escape_field(nil) == ""
    end
  end

  describe "line/1" do
    test "joins escaped fields with commas" do
      assert CSV.line(["a", "b,c", 1]) == "a,\"b,c\",1"
    end
  end
end
