defmodule Mewtwo.Compression do
  require Logger

  alias Mewtwo.TokenCounter
  alias Mewtwo.Compression.LineCompressor
  alias Mewtwo.Compression.FileSummarizer
  alias Mewtwo.Compression.PatternGrouper
  alias Mewtwo.Compression.Truncator

  @doc """
  Main compression pipeline: applies all stages and returns result

  Returns: {compressed_diff, metadata}

  Args:
    - diff_string: unified diff text
    - file_contents: map of file paths to contents (for context)
    - token_budget: hard ceiling on the compressed result. Files are dropped
      lowest-review-value first (lockfiles and build output before source)
      until the diff fits.
  """
  def compress(diff_string, file_contents, token_budget \\ 100_000) do
    # Stage 1: Estimate input tokens
    input_tokens = TokenCounter.count_tokens(diff_string, :code)

    Logger.info("[compression] start: #{byte_size(diff_string)} bytes / ~#{input_tokens} tokens")

    # Stage 2: Line-level compression
    step1 = LineCompressor.compress(diff_string)
    log_stage(:line_compress, input_tokens, step1)

    # Stage 3: File summarization
    step2 = FileSummarizer.summarize(step1, file_contents)
    log_stage(:file_summarize, nil, step2)

    # Stage 4: Pattern grouping
    step3 = PatternGrouper.group(step2)
    log_stage(:pattern_group, nil, step3)

    # Stage 5: Drop whole files if we are still over budget. Without this a
    # lockfile-heavy PR sails past every guard and the model rejects the
    # request outright.
    {step4, truncation} = Truncator.truncate(step3, token_budget)
    final_tokens = truncation.tokens

    log_truncation(truncation, token_budget)

    ratio = if input_tokens > 0, do: final_tokens / input_tokens, else: 1.0

    Logger.info(
      "[compression] done: #{input_tokens} -> #{final_tokens} tokens " <>
        "(#{Float.round((1.0 - ratio) * 100, 1)}% saved), " <>
        "#{step4 |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "@@"))} hunk headers kept"
    )

    {
      step4,
      %{
        original_tokens: input_tokens,
        compressed_tokens: final_tokens,
        ratio: ratio,
        truncated_sections: length(truncation.dropped),
        dropped_files: truncation.dropped,
        dropped_tokens: truncation.dropped_tokens,
        token_budget: token_budget,
        stages_applied: [:line_compress, :file_summarize, :pattern_group, :truncate]
      }
    }
  end

  # Passed as a closure so the per-stage TokenCounter pass only runs when debug
  # logging is actually enabled — it is a full scan of the diff.
  defp log_stage(stage, from, text) do
    Logger.debug(fn ->
      to = TokenCounter.count_tokens(text, :code)
      prefix = if from, do: "#{from} -> ", else: ""

      "[compression] #{stage}: #{prefix}#{to} tokens"
    end)
  end

  defp log_truncation(%{dropped: []}, _budget), do: :ok

  defp log_truncation(truncation, budget) do
    Logger.warning(
      "[compression] truncated to fit #{budget} tokens: dropped " <>
        "#{length(truncation.dropped)} file(s) totalling #{truncation.dropped_tokens} tokens"
    )

    Enum.each(Enum.take(truncation.dropped, 10), fn dropped ->
      Logger.warning(
        "[compression]   dropped #{dropped.file} (~#{dropped.tokens} tokens, #{dropped.reason})"
      )
    end)
  end
end
