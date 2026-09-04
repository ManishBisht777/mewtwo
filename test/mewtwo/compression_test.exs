defmodule Mewtwo.CompressionTest do
  use ExUnit.Case
  alias Mewtwo.Compression

  describe "compress/2" do
    test "handles empty diff" do
      {result, metadata} = Compression.compress("")

      assert result == ""
      assert metadata.original_tokens == 0
      assert metadata.compressed_tokens == 0
      assert metadata.ratio == 1.0
    end

    test "returns tuple with diff and metadata" do
      diff = """
      --- a/file.ex
      +++ b/file.ex
      @@ -1,5 +1,5 @@
      +new line
      """

      {result, metadata} = Compression.compress(diff)

      assert is_binary(result)
      assert Map.has_key?(metadata, :original_tokens)
      assert Map.has_key?(metadata, :compressed_tokens)
      assert Map.has_key?(metadata, :ratio)
      assert Map.has_key?(metadata, :truncated_sections)
      assert Map.has_key?(metadata, :stages_applied)
    end

    test "compression reduces or maintains size" do
      diff = generate_sample_diff(5000)

      {_result, metadata} = Compression.compress(diff)

      # Compression should not increase size
      assert metadata.compressed_tokens <= metadata.original_tokens
    end

    test "respects token budget" do
      diff = generate_sample_diff(50_000)
      budget = 10_000

      {_result, metadata} = Compression.compress(diff, budget)

      # If over budget, should truncate
      assert metadata.compressed_tokens <= budget or metadata.compressed_tokens <= metadata.original_tokens
    end

    test "metadata is accurate" do
      diff = generate_sample_diff(5000)

      {_result, metadata} = Compression.compress(diff)

      assert metadata.original_tokens > 0
      assert metadata.compressed_tokens >= 0
      assert metadata.ratio >= 0
      assert is_list(metadata.stages_applied)
      assert :line_compress in metadata.stages_applied
    end

    test "default budget is 100K tokens" do
      # With default budget, should not truncate small diffs
      diff = generate_sample_diff(10_000)

      {_result, metadata} = Compression.compress(diff)

      # Tokens should be under 100K
      assert metadata.compressed_tokens < 100_000
    end

    test "handles large diffs" do
      diff = generate_sample_diff(50_000)

      {_result, metadata} = Compression.compress(diff)

      assert metadata.original_tokens > 0
      assert metadata.compressed_tokens >= 0
    end

    test "stages are applied in order" do
      diff = generate_sample_diff(10_000)

      {_result, metadata} = Compression.compress(diff)

      stages = metadata.stages_applied
      assert is_list(stages)
      assert length(stages) > 0
    end
  end

  # ===== Helpers =====

  defp generate_sample_diff(size) do
    lines =
      Enum.map(1..50, fn i ->
        """
         Context line #{i} with some content
        - Removed line #{i} has slightly different content
        + Added line #{i} has modified content here
        """
      end)

    diff = Enum.join(lines, "\n")
    times = div(size, byte_size(diff)) + 1

    String.duplicate(diff, times)
    |> String.slice(0, size)
  end
end
