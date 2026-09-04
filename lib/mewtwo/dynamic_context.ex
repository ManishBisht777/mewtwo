defmodule Mewtwo.DynamicContext do
  require Logger

  alias Mewtwo.Context.{SymbolParser, CallerFinder, TestFinder, ConfigFinder}
  alias Mewtwo.TokenCounter

  @doc """
  Fetch all relevant context for a diff

  Returns: %{
    fetched_context: [...],
    skipped_items: [...],
    tokens_used: N,
    budget_note: "string"
  }
  """
  def fetch(diff_string, repo_path, token_budget \\ 15_000) do
    Logger.info("[context] start: repo_path=#{repo_path}, budget=#{token_budget} tokens")

    # Step 1: Parse changed symbols
    symbols = SymbolParser.parse(diff_string)

    Logger.info(
      "[context] symbols: #{length(Map.get(symbols, :functions, []))} functions, " <>
        "#{length(Map.get(symbols, :modules, []))} modules, " <>
        "#{length(Map.get(symbols, :imports, []))} imports"
    )

    # Step 2: Fetch all context
    callers =
      CallerFinder.find_callers(
        Map.get(symbols, :functions, []),
        repo_path
      )

    tests =
      TestFinder.find_tests(
        Map.get(symbols, :modules, []),
        repo_path
      )

    config = ConfigFinder.find_context(repo_path)

    # Step 3: Combine into context items
    all_items = combine_context(callers, tests, config)

    # Step 4: Rank by relevance
    ranked = rank_by_relevance(all_items)

    # Step 5: Budget-aware fetching
    {fetched, skipped, tokens} = budget_aware_fetch(ranked, token_budget)

    note =
      if tokens >= token_budget do
        "⚠️  Budget exhausted (#{tokens}/#{token_budget} tokens). Skipped #{length(skipped)} items."
      else
        "✓ Fetched #{length(fetched)} items (#{tokens}/#{token_budget} tokens)."
      end

    Logger.info(
      "[context] done: #{length(fetched)} items fetched, #{length(skipped)} skipped, " <>
        "#{tokens}/#{token_budget} tokens (#{by_type(fetched)})"
    )

    %{
      fetched_context: fetched,
      skipped_items: skipped,
      tokens_used: tokens,
      budget_note: note
    }
  end

  # "caller=28 config=7 docs=3" — which context kinds survived the budget.
  defp by_type([]), do: "none"

  defp by_type(items) do
    items
    |> Enum.frequencies_by(&Map.get(&1, :type, "unknown"))
    |> Enum.map_join(" ", fn {type, count} -> "#{type}=#{count}" end)
  end

  # Order matters: rank_by_relevance/1 breaks score ties by input order, so
  # callers -> tests -> config -> docs decides which items survive the budget.
  defp combine_context(callers, tests, config) do
    Enum.concat([
      Enum.flat_map(callers, fn {func, caller_list} ->
        Enum.map(caller_list, fn {file, line, depth} ->
          %{
            type: "caller",
            func: func,
            file: file,
            line: line,
            depth: depth,
            content: "#{func} called in #{file}:#{line}"
          }
        end)
      end),
      Enum.map(tests, fn {file, content} -> %{type: "test", file: file, content: content} end),
      Enum.map(config.config_files, fn file ->
        %{type: "config", file: file, content: File.read!(file)}
      end),
      Enum.map(config.docs, fn {file, content} ->
        %{type: "docs", file: file, content: content}
      end)
    ])
  end

  defp rank_by_relevance(items) do
    items
    |> Enum.map(fn item ->
      score = calculate_score(item)
      Map.put(item, :score, score)
    end)
    |> Enum.sort_by(fn item -> item.score end, :desc)
  end

  defp calculate_score(%{type: "caller", depth: 1}), do: 100
  defp calculate_score(%{type: "caller", depth: 2}), do: 50
  defp calculate_score(%{type: "test"}), do: 80
  defp calculate_score(%{type: "config"}), do: 70
  defp calculate_score(%{type: "docs"}), do: 30
  defp calculate_score(_), do: 10

  defp budget_aware_fetch(ranked_items, budget) do
    {fetched, skipped, tokens} =
      Enum.reduce(ranked_items, {[], [], 0}, fn item, {fetched, skipped, tokens} ->
        item_tokens = TokenCounter.count_tokens(item.content, :code)
        new_tokens = tokens + item_tokens

        if new_tokens <= budget do
          {[item | fetched], skipped, new_tokens}
        else
          {fetched, [item | skipped], tokens}
        end
      end)

    {Enum.reverse(fetched), Enum.reverse(skipped), tokens}
  end
end
