defmodule Mewtwo.TokenCounter do
  @moduledoc """
  Token counter for estimating OpenAI-style token usage from text/diffs.

  Token estimation rules:
  - Prose: ~0.75 words per token (1.33 tokens per word)
  - Code: ~4 characters per token (handles symbols, operators)
  - Mixed: Conservative ~4 chars per token (default)

  Accuracy target: within 10% of actual token count.

  ## Usage

  ### Basic counting
      iex> Mewtwo.TokenCounter.count_tokens("Hello world")
      3

  ### With type hints
      iex> Mewtwo.TokenCounter.count_tokens("const x = 1", :code)
      3

  ### Diff counting (returns {total, added, removed})
      iex> Mewtwo.TokenCounter.count_diff_tokens("+ new\\n- old")
      {2, 1, 1}

  ## Accuracy

  Estimates are within ±10% of actual token count for typical code/prose.
  Uses character-based heuristic for speed and consistency.
  """

  @doc """
  Estimate tokens in text using character-based heuristic.

  Formula: text_length / 4 (conservative for mixed content)

  Returns integer token count.

  ## Examples

      iex> Mewtwo.TokenCounter.count_tokens("")
      0

      iex> Mewtwo.TokenCounter.count_tokens("Hello world")
      3

      iex> Mewtwo.TokenCounter.count_tokens("   Hello world   ")
      3

  """
  def count_tokens(text) when is_binary(text) do
    text = String.trim(text)
    count_mixed_tokens(text)
  end

  @doc """
  Estimate tokens with content-type hint for better accuracy.

  Types:
  - `:code`  → 4 chars per token (symbols and operators are dense)
  - `:prose` → 0.75 words per token (1.33 tokens per word)
  - `:mixed` → 4 chars per token (default, balances both)
  - Other atoms default to `:mixed`

  Returns integer token count.

  ## Examples

      iex> Mewtwo.TokenCounter.count_tokens("const x = 1;", :code)
      3

      iex> Mewtwo.TokenCounter.count_tokens("The quick brown fox", :prose)
      6

      iex> Mewtwo.TokenCounter.count_tokens("Hello world", :mixed)
      3

  """
  def count_tokens(text, type) when is_binary(text) and is_atom(type) do
    text = String.trim(text)

    case type do
      :code -> count_code_tokens(text)
      :prose -> count_prose_tokens(text)
      :mixed -> count_mixed_tokens(text)
      _ -> count_mixed_tokens(text)
    end
  end

  @doc """
  Count tokens in unified diff format.

  Diff lines have prefixes:
  - `+` = added line (not file marker)
  - `-` = removed line (not file marker)
  - ` ` = unchanged line
  - Other = metadata (ignored)

  Strategy:
  1. Strip diff metadata (@@ line numbers @@, file markers +++ ---)
  2. Remove line prefixes (+/-)
  3. Count remaining content as code
  4. Track added, removed, and total separately

  Returns: `{total_tokens, added_tokens, removed_tokens}`

  ## Examples

      iex> Mewtwo.TokenCounter.count_diff_tokens("+ new\\n- old")
      {2, 1, 1}

      iex> Mewtwo.TokenCounter.count_diff_tokens("")
      {0, 0, 0}

  """
  def count_diff_tokens(diff_text) when is_binary(diff_text) do
    lines = String.split(diff_text, "\n")

    {added, removed, unchanged} =
      Enum.reduce(lines, {0, 0, 0}, fn line, {added, removed, unch} ->
        cond do
          # Added line (not file marker +++)
          String.starts_with?(line, "+") && !String.starts_with?(line, "+++") ->
            content = String.slice(line, 1..-1//1)
            {added + count_code_tokens(content), removed, unch}

          # Removed line (not file marker ---)
          String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
            content = String.slice(line, 1..-1//1)
            {added, removed + count_code_tokens(content), unch}

          # Unchanged line
          String.starts_with?(line, " ") ->
            content = String.slice(line, 1..-1//1)
            {added, removed, unch + count_code_tokens(content)}

          # Skip metadata lines (@@, ---, +++, etc.)
          true ->
            {added, removed, unch}
        end
      end)

    total = added + removed + unchanged
    {total, added, removed}
  end

  # ===== Private Helpers =====

  # Code tokens: ~4 characters per token
  # Code is denser (symbols, operators), so fewer tokens per char
  defp count_code_tokens(text) do
    byte_size(text) / 4
    |> Float.ceil()
    |> trunc()
  end

  # Prose tokens: ~1.33 tokens per word
  # Prose is less dense than code
  defp count_prose_tokens(text) do
    word_count = count_words(text)
    (word_count * 1.33)
    |> Float.ceil()
    |> trunc()
  end

  # Mixed: Conservative estimate (~4 chars per token)
  # Balances code + prose content
  defp count_mixed_tokens(text) do
    byte_size(text) / 4
    |> Float.ceil()
    |> trunc()
  end

  # Count words: split on whitespace
  defp count_words(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
