defmodule Mewtwo.Compression do
  alias Mewtwo.TokenCounter
  alias Mewtwo.Compression.LineCompressor
  alias Mewtwo.Compression.FileSummarizer
  alias Mewtwo.Compression.PatternGrouper

  @doc """
  Main compression pipeline: applies all stages and returns result

  Returns: {compressed_diff, metadata}

  Args:
    - diff_string: unified diff text
    - file_contents: map of file paths to contents (for context)
    - token_budget: reserved for Phase 2 truncation (ignored in v1)
  """
  def compress(diff_string, file_contents, _token_budget \\ 100_000) do
    # Stage 1: Estimate input tokens
    input_tokens = TokenCounter.count_tokens(diff_string, :code)

    # Stage 2: Line-level compression
    step1 = LineCompressor.compress(diff_string)
    _step1_tokens = TokenCounter.count_tokens(step1, :code)

    # Stage 3: File summarization
    step2 = FileSummarizer.summarize(step1, file_contents)
    _step2_tokens = TokenCounter.count_tokens(step2, :code)

    # Stage 4: Pattern grouping
    step3 = PatternGrouper.group(step2)
    final_tokens = TokenCounter.count_tokens(step3, :code)

    # TODO (Phase 2): Add priority-based truncation if over token budget
    # If final_tokens > budget, selectively remove test files, configs, comments
    # For v1: return full compressed diff without truncation

    # Return: compressed diff + metadata (no truncation in this version)
    ratio = if input_tokens > 0, do: final_tokens / input_tokens, else: 1.0

    {
      step3,
      %{
        original_tokens: input_tokens,
        compressed_tokens: final_tokens,
        ratio: ratio,
        truncated_sections: 0,
        stages_applied: [:line_compress, :file_summarize, :pattern_group]
      }
    }
  end

end
