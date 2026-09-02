defmodule Mewtwo.Compression.FileSummarizer do
  @doc """
  Replaces large unchanged sections with summaries
  """
  def summarize(compressed_diff, file_contents) do
    compressed_diff
    |> String.split("\n")
    |> group_by_file()
    |> Enum.map(&summarize_file(&1, file_contents))
    |> Enum.flat_map(fn {header, lines} -> [header | lines] end)
    |> Enum.join("\n")
  end

  # For each file in the diff:
  # 1. Identify unchanged sections (no +/- prefix)
  # 2. If unchanged section > 50 lines, replace with comment
  # 3. Comment format: "... 123 unchanged lines (lines 450-573) ..."
  # 4. Keep all changed lines intact

  defp summarize_file({file_header, hunk_lines}, _file_contents) do
    summarized_lines = summarize_hunk_lines(hunk_lines, 50)
    {file_header, summarized_lines}
  end

  defp summarize_hunk_lines(lines, threshold) do
    summarize_hunk_lines(lines, [], 0, threshold)
  end

  defp summarize_hunk_lines([], result, unchanged_count, threshold) do
    if unchanged_count > threshold do
      result ++ ["// ... #{unchanged_count} unchanged lines ..."]
    else
      result
    end
  end

  defp summarize_hunk_lines([line | rest], result, unchanged_count, threshold) do
    is_changed = String.starts_with?(line, "+") || String.starts_with?(line, "-")

    if is_changed do
      new_result =
        if unchanged_count > threshold do
          result ++ ["// ... #{unchanged_count} unchanged lines ..."]
        else
          result
        end

      summarize_hunk_lines(rest, new_result ++ [line], 0, threshold)
    else
      summarize_hunk_lines(rest, result, unchanged_count + 1, threshold)
    end
  end

  defp group_by_file(diff_lines) do
    {groups, current_file} =
      Enum.reduce(diff_lines, {[], nil}, fn line, {groups, current_file} ->
        if String.starts_with?(line, "--- a/") || String.starts_with?(line, "--- /") do
          groups = if current_file, do: [current_file | groups], else: groups
          {groups, {line, []}}
        else
          if current_file do
            header = elem(current_file, 0)
            lines = elem(current_file, 1)
            {groups, {header, lines ++ [line]}}
          else
            {groups, current_file}
          end
        end
      end)

    groups = if current_file, do: [current_file | groups], else: groups
    Enum.reverse(groups)
  end
end
