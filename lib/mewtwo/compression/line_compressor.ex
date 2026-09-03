defmodule Mewtwo.Compression.LineCompressor do
  @moduledoc """
  Trims each hunk down to changed lines plus a small context window.

  A unified diff is a sequence of file-header lines (`diff --git`, `index`,
  `--- a/`, `+++ b/`) and `@@` hunks. Header lines pass through untouched;
  only hunk bodies get their context trimmed.
  """

  @context_lines 3

  @doc """
  Takes a unified diff and returns it with only #{@context_lines}-line context around changes
  """
  def compress(diff_string) do
    diff_string
    |> String.split("\n")
    |> parse_sections()
    |> Enum.flat_map(&render_section/1)
    |> Enum.join("\n")
  end

  # Anything that is not inside a hunk is preserved verbatim and in order.
  # Treating pre-hunk header lines as hunk content used to drop them, which in
  # turn made the downstream file grouping discard the whole first file — a
  # single-file diff compressed to an empty string.
  defp parse_sections(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      cond do
        String.starts_with?(line, "@@") ->
          [{:hunk, line, []} | acc]

        file_header?(line) ->
          [{:verbatim, line} | acc]

        true ->
          case acc do
            [{:hunk, header, hunk_lines} | rest] -> [{:hunk, header, [line | hunk_lines]} | rest]
            _ -> [{:verbatim, line} | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp file_header?(line) do
    String.starts_with?(line, ["diff --git", "index ", "--- ", "+++ ", "new file mode", "deleted file mode", "similarity index", "rename from", "rename to", "Binary files"])
  end

  defp render_section({:verbatim, line}), do: [line]

  defp render_section({:hunk, header, reversed_lines}) do
    [header | trim_context(Enum.reverse(reversed_lines))]
  end

  # Keep every changed line, plus @context_lines either side. Overlapping
  # windows merge, so dense hunks come through essentially intact.
  defp trim_context([]), do: []

  defp trim_context(lines) do
    changed =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} -> changed?(line) end)
      |> Enum.map(fn {_, index} -> index end)

    case changed do
      [] ->
        []

      indexes ->
        keep =
          indexes
          |> Enum.flat_map(fn index ->
            Range.new(max(0, index - @context_lines), min(length(lines) - 1, index + @context_lines))
          end)
          |> Enum.uniq()
          |> Enum.sort()

        Enum.map(keep, &Enum.at(lines, &1))
    end
  end

  defp changed?(line), do: String.starts_with?(line, ["+", "-"])
end
