defmodule Mewtwo.Compression.PatternGrouper do
  @doc """
  Groups repetitive changes across files
  """
  def group(compressed_diff) do
    compressed_diff
    |> String.split("\n")
    |> extract_changes()  # [%{file, pattern, change}, ...]
    |> identify_patterns() # {pattern => [files], ...}
    |> group_repetitive()  # Filter patterns with count > threshold
    |> apply_grouping(compressed_diff)
  end

  # Detect patterns like:
  # - Variable renames: "old_name" → "new_name" (same across files)
  # - Import additions: same new import in multiple files
  # - Function signature changes: same change in multiple files

  defp extract_changes(lines) do
    Enum.reduce(lines, {[], nil}, fn line, {changes, current_file} ->
      cond do
        String.starts_with?(line, "--- a/") || String.starts_with?(line, "--- /") ->
          {changes, String.trim_leading(line, "--- a/") |> String.trim_leading("--- /")}

        String.starts_with?(line, "+") && !String.starts_with?(line, "+++") ->
          content = String.slice(line, 1..-1//1)
          pattern = normalize_pattern(content)
          {changes ++ [%{file: current_file, change: content, pattern: pattern, type: :added}], current_file}

        String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
          content = String.slice(line, 1..-1//1)
          pattern = normalize_pattern(content)
          {changes ++ [%{file: current_file, change: content, pattern: pattern, type: :removed}], current_file}

        true ->
          {changes, current_file}
      end
    end)
    |> elem(0)
  end

  defp normalize_pattern(text) do
    text
    |> String.replace(~r/"[^"]*"/, "\"STRING\"")
    |> String.replace(~r/'[^']*'/, "'STRING'")
    |> String.replace(~r/:\s*\d+/, ": NUM")
    |> String.replace(~r/\b\d{4,}\b/, "NUM")
  end

  defp identify_patterns(changes) do
    Enum.reduce(changes, %{}, fn %{pattern: pattern, change: change, file: file, type: type}, acc ->
      key = {pattern, change, type}
      case Map.get(acc, key) do
        nil -> Map.put(acc, key, {1, [file]})
        {count, files} -> Map.put(acc, key, {count + 1, [file | files]})
      end
    end)
  end

  defp group_repetitive(patterns) do
    Enum.filter(patterns, fn {_key, {count, _files}} -> count > 3 end)
    |> Enum.into(%{})
  end

  defp apply_grouping(grouped_patterns, diff) do
    if map_size(grouped_patterns) == 0 do
      diff
    else
      apply_grouping_to_diff(diff, grouped_patterns)
    end
  end

  defp apply_grouping_to_diff(diff, _grouped_patterns) do
    # For now, return diff as-is
    # Pattern grouping requires tracking which lines match patterns and replacing them
    # This is complex due to maintaining diff structure
    # TODO: Implement full pattern replacement with examples
    diff
  end
end
