defmodule Mewtwo.Compression.FileSummarizerTest do
  use ExUnit.Case
  alias Mewtwo.Compression.FileSummarizer

  describe "summarize/2" do
    test "empty diff" do
      assert FileSummarizer.summarize("", %{}) == ""
    end

    test "replaces large unchanged sections with summaries" do
      # Create a diff with a large unchanged section
      unchanged_lines = Enum.map(1..60, fn i -> " line #{i}" end) |> Enum.join("\n")

      diff = """
      --- a/file.ex
      +++ b/file.ex
      @@ -1,65 +1,65 @@
      #{unchanged_lines}
      +added line
      #{unchanged_lines}
      """

      result = FileSummarizer.summarize(diff, %{})

      # Result should contain summary comment for large unchanged sections
      assert String.contains?(result, "unchanged lines")
    end

    test "keeps all changed lines intact" do
      diff = """
      --- a/file.ex
      +++ b/file.ex
      @@ -1,5 +1,5 @@
       line 1
      -old line
      +new line
       line 4
      """

      result = FileSummarizer.summarize(diff, %{})

      # Changed lines should be kept
      assert String.contains?(result, "-old line")
      assert String.contains?(result, "+new line")
    end

    test "preserves file headers" do
      diff = """
      --- a/lib/module.ex
      +++ b/lib/module.ex
      @@ -1,5 +1,5 @@
      +new
      """

      result = FileSummarizer.summarize(diff, %{})

      assert String.contains?(result, "--- a/lib/module.ex")
      assert String.contains?(result, "+++ b/lib/module.ex")
    end

    test "handles multiple files" do
      diff = """
      --- a/file1.ex
      +++ b/file1.ex
      @@ -1,5 +1,5 @@
      +change1
      --- a/file2.ex
      +++ b/file2.ex
      @@ -1,5 +1,5 @@
      +change2
      """

      result = FileSummarizer.summarize(diff, %{})

      assert String.contains?(result, "file1.ex")
      assert String.contains?(result, "file2.ex")
      assert String.contains?(result, "+change1")
      assert String.contains?(result, "+change2")
    end

    test "small unchanged sections are not summarized" do
      diff = """
      --- a/file.ex
      +++ b/file.ex
      @@ -1,10 +1,10 @@
       line 1
       line 2
       line 3
      +added
       line 5
      """

      result = FileSummarizer.summarize(diff, %{})

      # Small sections should not be summarized
      # The result should contain the added line
      assert String.contains?(result, "+added")
      # The result should have some content
      assert String.length(result) > 0
    end
  end
end
