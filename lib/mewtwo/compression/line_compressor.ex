defmodule Mewtwo.Compression.LineCompressor do
  @doc """
  Takes a unified diff and returns it with only 3-line context around changes
  """
  def compress(diff_string) do
    diff_string
    |> String.split("\n")
    |> parse_hunks()
    |> compress_hunks()
    |> Enum.flat_map(fn %{header: header, lines: lines} -> [header | lines] end)
    |> Enum.join("\n")
  end

  # Parser: Split diff into hunks (sections starting with @@)
  # Each hunk: {hunk_header, [lines]}
  defp parse_hunks(lines) do
    {hunks, current_hunk} =
      Enum.reduce(lines, {[], nil}, fn line, {hunks, current_hunk} ->
        if String.starts_with?(line, "@@") do
          hunks = if current_hunk, do: [current_hunk | hunks], else: hunks
          {hunks, %{header: line, lines: []}}
        else
          if current_hunk do
            {hunks, Map.update!(current_hunk, :lines, &(&1 ++ [line]))}
          else
            {hunks, current_hunk}
          end
        end
      end)

    (if current_hunk, do: [current_hunk | hunks], else: hunks)
    |> Enum.reverse()
  end

  # Compressor: For each hunk, keep only changed lines + 3-line context
  # Algorithm:
  # 1. Find lines starting with "+" or "-" (actual changes)
  # 2. For each change, keep 3 lines before and 3 lines after
  # 3. Remove duplicate context (overlapping windows merge)
  # 4. Return new hunk with minimal context
  defp compress_hunks(hunks) do
    Enum.map(hunks, &compress_hunk/1)
  end

  defp compress_hunk(%{header: header, lines: lines}) do
    if lines == [] do
      %{header: header, lines: []}
    else
      # Find indices of changed lines
      changed_indices =
        lines
        |> Enum.with_index()
        |> Enum.filter(fn {line, _} -> String.starts_with?(line, "+") || String.starts_with?(line, "-") end)
        |> Enum.map(fn {_, idx} -> idx end)

      if changed_indices == [] do
        # No changes, return empty hunk
        %{header: header, lines: []}
      else
        # Build context windows: keep 3 lines before and 3 lines after each change
        needed_indices =
          changed_indices
          |> Enum.flat_map(fn idx ->
            Range.new(max(0, idx - 3), min(length(lines) - 1, idx + 3))
          end)
          |> Enum.uniq()
          |> Enum.sort()

        # Extract lines at needed indices
        kept_lines = Enum.map(needed_indices, &Enum.at(lines, &1))

        %{header: header, lines: kept_lines}
      end
    end
  end
end
