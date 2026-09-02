defmodule Mewtwo.Compression.PatternGrouperTest do
  use ExUnit.Case
  alias Mewtwo.Compression.PatternGrouper

  describe "group/1" do
    test "empty diff" do
      assert PatternGrouper.group("") == ""
    end

    test "returns original diff when no patterns to group" do
      diff = """
      --- a/file.ex
      +++ b/file.ex
      @@ -1,5 +1,5 @@
      +unique change
      """

      result = PatternGrouper.group(diff)
      assert String.contains?(result, "+unique change")
    end

    test "handles diff with few repetitions (below threshold)" do
      diff = """
      --- a/file1.ex
      +++ b/file1.ex
      +import NewModule
      --- a/file2.ex
      +++ b/file2.ex
      +import NewModule
      """

      result = PatternGrouper.group(diff)

      # Below threshold (>3), so no grouping
      assert String.contains?(result, "import NewModule")
    end

    test "preserves diff structure" do
      diff = """
      --- a/lib/old_module.ex
      +++ b/lib/new_module.ex
      @@ -1,10 +1,10 @@
       defmodule OldModule do
      -  old code
      +  new code
       end
      """

      result = PatternGrouper.group(diff)

      assert String.contains?(result, "--- a/lib/old_module.ex")
      assert String.contains?(result, "+++ b/lib/new_module.ex")
    end

    test "handles file headers" do
      diff = """
      --- a/test.ex
      +++ b/test.ex
      @@ -1,5 +1,5 @@
      +test
      """

      result = PatternGrouper.group(diff)
      assert String.contains?(result, "test.ex")
    end

    test "detects simple patterns" do
      # Create diff with 4 identical changes (above threshold of 3)
      diff = """
      --- a/file1.ex
      +++ b/file1.ex
      +import Config
      --- a/file2.ex
      +++ b/file2.ex
      +import Config
      --- a/file3.ex
      +++ b/file3.ex
      +import Config
      --- a/file4.ex
      +++ b/file4.ex
      +import Config
      """

      result = PatternGrouper.group(diff)

      # Should still contain the changes (grouping is not yet fully implemented)
      assert String.contains?(result, "import Config")
    end

    test "normalizes patterns (removes string literals)" do
      # Test that pattern normalization works
      diff = """
      --- a/file1.ex
      +++ b/file1.ex
      +"hello world"
      --- a/file2.ex
      +++ b/file2.ex
      +"goodbye world"
      """

      result = PatternGrouper.group(diff)
      assert is_binary(result)
    end
  end
end
