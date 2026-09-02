defmodule Mewtwo.Context.CallerFinder do
  @doc "Find callers of changed functions"
  def find_callers(functions, repo_path) do
    functions
    |> Enum.map(fn func ->
      callers = grep_for_callers(func, repo_path)
      ranked = rank_callers(callers)
      {func, Enum.take(ranked, 10)}
    end)
    |> Enum.into(%{})
  end

  defp grep_for_callers(function_name, repo_path) do
    cmd = "grep -rn '#{function_name}(' '#{repo_path}' --include='*.ex' --include='*.exs' 2>/dev/null || true"

    case System.cmd("sh", ["-c", cmd]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_grep_result/1)
        |> Enum.reject(&is_nil/1)

      {_output, _status} ->
        []
    end
  end

  defp parse_grep_result(line) do
    case String.split(line, ":", parts: 3) do
      [file, line_num, _content] ->
        case Integer.parse(line_num) do
          {num, _} -> {file, num}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp calculate_depth(file_path) do
    cond do
      String.contains?(file_path, "/lib/") -> 1
      String.contains?(file_path, "/test/") -> 2
      true -> 3
    end
  end

  defp rank_callers(callers) do
    callers
    |> Enum.map(fn {file, line} ->
      {file, line, calculate_depth(file)}
    end)
    |> Enum.sort_by(fn {_, _, depth} -> depth end)
  end
end
