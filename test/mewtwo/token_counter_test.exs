defmodule Mewtwo.TokenCounterTest do
  use ExUnit.Case
  doctest Mewtwo.TokenCounter

  alias Mewtwo.TokenCounter

  describe "count_tokens/2" do
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

    test "code: 4 chars per token" do
      # "const x = 1;" = 12 chars → 3 tokens
      assert TokenCounter.count_tokens("const x = 1;", :code) == 3
    end

    test "code: longer example" do
      code = "defmodule MyModule do\n  def hello(name) do\n    \"Hello, #\{name}!\"\n  end\nend"
      # 74 chars → 19 tokens
      assert TokenCounter.count_tokens(code, :code) == 19
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
  end
end
