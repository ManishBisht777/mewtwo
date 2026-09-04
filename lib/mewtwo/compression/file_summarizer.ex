defmodule Mewtwo.Compression.FileSummarizer do
  @doc """
  Replaces large unchanged sections with summaries
  """
  def summarize(compressed_diff) do
    compressed_diff
    |> String.split("\n")
    |> group_by_file()
    |> Enum.map(&summarize_file/1)
    |> Enum.flat_map(fn {header, lines} -> [header | lines] end)
    |> Enum.join("\n")
  end

  # For each file in the diff:
  # 1. Identify runs of unchanged (context) lines
  # 2. If a run exceeds the threshold, replace it with a marker
  # 3. Keep shorter runs verbatim, along with every changed line and @@ header

  @threshold 50

  defp summarize_file({file_header, hunk_lines}) do
    {file_header, summarize_hunk_lines(hunk_lines, @threshold)}
  end

  defp summarize_hunk_lines(lines, threshold) do
    lines
    |> Enum.chunk_by(&collapsible?/1)
    |> Enum.flat_map(&collapse_run(&1, threshold))
  end

  defp collapse_run([first | _] = run, threshold) do
    if collapsible?(first) and length(run) > threshold do
      # Rendered as a diff context line so it does not read as code the
      # agents might report a finding against.
      [" ... #{length(run)} unchanged lines ..."]
    else
      run
    end
  end

  # Changed lines and @@ hunk headers must always survive.
  #
  # The @@ header is the only place line numbers appear in a unified diff, and
  # findings are reported by line — dropping it leaves agents no choice but to
  # invent locations. Short runs of context are kept too: without the
  # surrounding lines a function body reads as truncated, which reliably
  # produces hallucinated "missing end" and misread-return findings.
  defp collapsible?(line) do
    not (String.starts_with?(line, "+") or String.starts_with?(line, "-") or
           String.starts_with?(line, "@@"))
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
