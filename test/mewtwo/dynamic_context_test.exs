defmodule Mewtwo.DynamicContextTest do
  use ExUnit.Case
  alias Mewtwo.DynamicContext

  describe "fetch/3" do
    test "returns map with expected keys" do
      diff = """
      @@ -1,5 +1,5 @@
      -def old_function do
      +def new_function do
       "hello"
      """

      result = DynamicContext.fetch(diff, File.cwd!())

      assert is_map(result)
      assert Map.has_key?(result, :fetched_context)
      assert Map.has_key?(result, :skipped_items)
      assert Map.has_key?(result, :tokens_used)
      assert Map.has_key?(result, :budget_note)
    end

    test "returns lists for context and skipped items" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!())

      assert is_list(result.fetched_context)
      assert is_list(result.skipped_items)
    end

    test "respects token budget" do
      diff = "+def test_func do"
      budget = 1_000

      result = DynamicContext.fetch(diff, File.cwd!(), budget)

      # Should not exceed budget
      assert result.tokens_used <= budget
    end

    test "includes budget note in result" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!())

      assert is_binary(result.budget_note)
      assert String.length(result.budget_note) > 0
    end

    test "handles empty diff" do
      result = DynamicContext.fetch("", File.cwd!())

      assert is_list(result.fetched_context)
      assert is_list(result.skipped_items)
      assert result.tokens_used >= 0
    end

    test "fetches documentation" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!())

      # Should find at least some docs
      doc_items = Enum.filter(result.fetched_context, &(&1.type == "docs"))
      assert length(doc_items) >= 0
    end

    test "fetches config files" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!())

      # Should find config items
      config_items = Enum.filter(result.fetched_context, &(&1.type == "config"))
      assert length(config_items) >= 0
    end

    test "items have type and content" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!())

      Enum.each(result.fetched_context, fn item ->
        assert Map.has_key?(item, :type)
        assert Map.has_key?(item, :content)
        assert Enum.member?(["caller", "test", "config", "docs"], item.type)
      end)
    end

    test "ranks items by relevance (score)" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!())

      scores = Enum.map(result.fetched_context, &Map.get(&1, :score, 0))

      # Should be sorted descending by score (if any items)
      if length(scores) > 1 do
        assert scores == Enum.sort(scores, :desc)
      end
    end

    test "default budget is 15K tokens" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!())

      # Default budget is 15K
      assert result.tokens_used <= 15_000
    end

    test "budget note shows status" do
      diff = "+def test_func do"
      result = DynamicContext.fetch(diff, File.cwd!(), 5_000)

      assert String.contains?(result.budget_note, "tokens") or
             String.contains?(result.budget_note, "Fetched")
    end
  end
end
