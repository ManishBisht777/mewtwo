defmodule Mewtwo.TokenCounterTest do
  use ExUnit.Case
  doctest Mewtwo.TokenCounter

  alias Mewtwo.TokenCounter

  describe "count_tokens/1 (default mixed)" do
    test "empty string" do
      assert TokenCounter.count_tokens("") == 0
    end

    test "short text" do
      # "Hello world" = 11 chars → 11/4 = 2.75 → 3 tokens
      assert TokenCounter.count_tokens("Hello world") == 3
    end

    test "100-char string" do
      text = String.duplicate("a", 100)
      # 100 / 4 = 25
      assert TokenCounter.count_tokens(text) == 25
    end

    test "strips leading/trailing whitespace" do
      text = "   Hello world   "
      # "Hello world" = 11 chars → 3 tokens
      assert TokenCounter.count_tokens(text) == 3
    end

    test "multiline text" do
      text = "line one\nline two\nline three"
      # 28 chars → 7 tokens
      assert TokenCounter.count_tokens(text) == 7
    end
  end

  describe "count_tokens/2 with type hint" do
    test "code: 4 chars per token" do
      # "const x = 1;" = 12 chars → 3 tokens
      assert TokenCounter.count_tokens("const x = 1;", :code) == 3
    end

    test "code: longer example" do
      code = "defmodule MyModule do\n  def hello(name) do\n    \"Hello, #\{name}!\"\n  end\nend"
      # 74 chars → 19 tokens
      assert TokenCounter.count_tokens(code, :code) == 19
    end

    test "prose: 1.33 tokens per word" do
      # "The quick brown fox" = 4 words → 4 * 1.33 = 5.32 → 6 tokens
      assert TokenCounter.count_tokens("The quick brown fox", :prose) == 6
    end

    test "prose: longer example" do
      prose =
        "The quick brown fox jumps over the lazy dog and runs through the forest"

      # 14 words → 14 * 1.33 = 18.62 → 19 tokens
      assert TokenCounter.count_tokens(prose, :prose) == 19
    end

    test "mixed: 4 chars per token (default)" do
      text = "Hello world"
      assert TokenCounter.count_tokens(text, :mixed) ==
             TokenCounter.count_tokens(text)
    end

    test "unknown type defaults to mixed" do
      text = "Hello world"
      assert TokenCounter.count_tokens(text, :unknown) ==
             TokenCounter.count_tokens(text)
    end

    test "nil type defaults to mixed" do
      text = "Hello world"
      assert TokenCounter.count_tokens(text, nil) ==
             TokenCounter.count_tokens(text)
    end
  end

  describe "count_diff_tokens/1" do
    test "empty diff" do
      {total, added, removed} = TokenCounter.count_diff_tokens("")
      assert total == 0
      assert added == 0
      assert removed == 0
    end

    test "simple 2-line diff" do
      diff = """
      - old line
      + new line
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      # With heredoc formatting, slightly more content
      assert added == 3
      assert removed == 3
      assert total == 6
    end

    test "diff with context lines" do
      diff = """
       unchanged line
      - removed line
      + added line
       another unchanged
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      assert added == 3
      assert removed == 4
      assert total == 16
    end

    test "ignores file markers (+++, ---)" do
      diff = """
      --- a/file.py
      +++ b/file.py
      + new content
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      # Only counts "+ new content" (12 chars → 3 tokens)
      assert added == 3
      assert removed == 0
      assert total == 3
    end

    test "ignores hunk markers (@@)" do
      diff = """
      @@ -10,5 +10,6 @@
      + new line
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      assert added == 3
      assert removed == 0
      assert total == 3
    end

    test "complex diff with multiple changes" do
      diff = """
      --- a/lib/module.ex
      +++ b/lib/module.ex
      @@ -5,3 +5,4 @@
         def hello(name) do
      -    "Hello world"
      +    "Hello, #\{name}!"
         end
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      assert added == 6
      assert removed == 5
      assert total == 18
    end

    test "diff with empty lines" do
      diff = """
      - removed

      + added
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      # "removed" = 7 chars → 2 tokens
      # "added" = 5 chars → 2 tokens
      # empty line = 0 chars → 0 tokens
      assert added == 2
      assert removed == 2
      assert total == 4
    end
  end

  describe "accuracy margin check" do
    test "10KB diff estimate is reasonable" do
      diff = generate_sample_diff(10_000)
      {total, _added, _removed} = TokenCounter.count_diff_tokens(diff)

      # 10KB should be ~2500 tokens
      # Accept reasonable range: 2000-3000
      assert total >= 2000
      assert total <= 3000
    end

    test "100KB diff estimate is reasonable" do
      diff = generate_sample_diff(100_000)
      {total, _added, _removed} = TokenCounter.count_diff_tokens(diff)

      # 100KB should be ~25000 tokens
      # Accept reasonable range: 20000-30000
      assert total >= 20_000
      assert total <= 30_000
    end
  end

  describe "edge cases" do
    test "handles unicode characters" do
      # "café" = 5 bytes (é is 2 bytes in UTF-8)
      text = "café"
      tokens = TokenCounter.count_tokens(text)
      # 5 / 4 = 1.25 → 2 tokens
      assert tokens == 2
    end

    test "handles special characters and symbols" do
      # "!@#$%^&*()" = 10 chars → 3 tokens
      text = "!@#$%^&*()"
      assert TokenCounter.count_tokens(text, :code) == 3
    end

    test "handles tabs and mixed whitespace" do
      text = "hello\t\tworld\n\ntest"
      result = TokenCounter.count_tokens(text)
      # After trim: "hello\t\tworld\n\ntest" = 18 bytes → 5 tokens
      assert result == 5
    end

    test "handles very long lines" do
      long_line = String.duplicate("a", 10_000)
      tokens = TokenCounter.count_tokens(long_line)
      # 10_000 / 4 = 2500
      assert tokens == 2500
    end

    test "diff with only additions" do
      diff = """
      + added 1
      + added 2
      + added 3
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      # Each line ~8-9 chars → 2-3 tokens each
      assert removed == 0
      assert added > 0
      assert total == added
    end

    test "diff with only removals" do
      diff = """
      - removed 1
      - removed 2
      - removed 3
      """

      {total, added, removed} = TokenCounter.count_diff_tokens(diff)

      assert added == 0
      assert removed > 0
      assert total == removed
    end
  end

  # ===== Helpers =====

  defp generate_sample_diff(size) do
    lines =
      Enum.map(1..100, fn i ->
        """
         Context line #{i} with some content
        - Removed line #{i} has slightly different content
        + Added line #{i} has modified content here
        """
      end)

    diff = Enum.join(lines, "\n")
    # Repeat to reach target size
    times = div(size, byte_size(diff)) + 1

    String.duplicate(diff, times)
    |> String.slice(0, size)
  end
end
