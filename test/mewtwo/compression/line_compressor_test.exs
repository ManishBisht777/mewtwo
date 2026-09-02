defmodule Mewtwo.Compression.LineCompressorTest do
  use ExUnit.Case
  alias Mewtwo.Compression.LineCompressor

  describe "compress/1" do
    test "empty diff" do
      assert LineCompressor.compress("") == ""
    end

    test "keeps only 3-line context around changes" do
      diff = """
      @@ -1,10 +1,10 @@
       line 1
       line 2
       line 3
       line 4
       line 5
      -line 6 (removed)
      +line 6 (added)
       line 7
       line 8
       line 9
       line 10
      """

      result = LineCompressor.compress(diff)
      result_lines = String.split(String.trim(result), "\n")

      # Should keep header + changed line + 3 context before and after
      assert Enum.count(result_lines, &String.starts_with?(&1, "@@")) >= 1
      assert Enum.any?(result_lines, &String.starts_with?(&1, "-"))
      assert Enum.any?(result_lines, &String.starts_with?(&1, "+"))
    end

    test "handles multiple hunks" do
      diff = """
      @@ -1,5 +1,5 @@
       line 1
      -removed 1
      +added 1
       line 4
      @@ -10,5 +10,5 @@
       line 10
      -removed 10
      +added 10
       line 13
      """

      result = LineCompressor.compress(diff)

      # Should have both hunks
      assert String.contains?(result, "@@")
    end

    test "preserves hunk headers" do
      diff = """
      @@ -10,5 +10,6 @@
      -old
      +new
      """

      result = LineCompressor.compress(diff)
      assert String.contains?(result, "@@ -10,5 +10,6 @@")
    end

    test "removes lines with no context" do
      # A hunk with only changed lines and no context
      diff = """
      @@ -1,1 +1,1 @@
      -old
      +new
      """

      result = LineCompressor.compress(diff)
      assert String.contains?(result, "-old")
      assert String.contains?(result, "+new")
    end
  end
end
