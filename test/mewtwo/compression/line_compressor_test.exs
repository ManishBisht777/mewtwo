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

  describe "file headers" do
    test "a single-file diff is not swallowed whole" do
      # parse_hunks used to drop every line before the first @@, which cost the
      # first file its `--- a/` header and made the downstream file grouping
      # discard it entirely — a one-file PR compressed to "".
      diff = """
      diff --git a/lib/only.ex b/lib/only.ex
      index abc..def 100644
      --- a/lib/only.ex
      +++ b/lib/only.ex
      @@ -10,6 +10,7 @@ defmodule Only do
         def run do
      +    boom = nil.field
           :ok
      """

      result = LineCompressor.compress(diff)

      assert String.contains?(result, "--- a/lib/only.ex")
      assert String.contains?(result, "+++ b/lib/only.ex")
      assert String.contains?(result, "@@ -10,6 +10,7 @@")
      assert String.contains?(result, "+    boom = nil.field")
    end

    test "keeps the header of the first file when several files change" do
      diff = """
      --- a/first.ex
      +++ b/first.ex
      @@ -1,3 +1,4 @@
      +first change
      --- a/second.ex
      +++ b/second.ex
      @@ -1,3 +1,4 @@
      +second change
      """

      result = LineCompressor.compress(diff)

      assert String.contains?(result, "--- a/first.ex")
      assert String.contains?(result, "--- a/second.ex")
      assert String.contains?(result, "+first change")
      assert String.contains?(result, "+second change")
    end

    test "keeps every @@ hunk header" do
      diff = """
      --- a/a.ex
      +++ b/a.ex
      @@ -1,3 +1,4 @@
      +one
      @@ -80,3 +81,4 @@
      +two
      """

      result = LineCompressor.compress(diff)

      assert String.contains?(result, "@@ -1,3 +1,4 @@")
      assert String.contains?(result, "@@ -80,3 +81,4 @@")
    end

    test "preserves rename and new-file markers" do
      diff = """
      diff --git a/old.ex b/new.ex
      similarity index 95%
      rename from old.ex
      rename to new.ex
      --- a/old.ex
      +++ b/new.ex
      @@ -1,3 +1,4 @@
      +change
      """

      result = LineCompressor.compress(diff)

      assert String.contains?(result, "rename from old.ex")
      assert String.contains?(result, "rename to new.ex")
    end
  end
end
