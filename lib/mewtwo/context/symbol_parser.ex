defmodule Mewtwo.Context.SymbolParser do
  @doc "Extract changed symbols from diff"
  def parse(diff_string) do
    lines = String.split(diff_string, "\n")

    %{
      functions: extract_functions(lines),
      modules: extract_modules(lines),
      imports: extract_imports(lines)
    }
  end

  defp extract_functions(lines) do
    lines
    |> Enum.filter(&is_changed/1)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/def[p]?\s+(\w+)/, line) do
        [_, name] -> [name]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  defp extract_modules(lines) do
    lines
    |> Enum.filter(&is_changed/1)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/defmodule\s+([A-Z]\w*)/, line) do
        [_, name] -> [name]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  defp extract_imports(lines) do
    lines
    |> Enum.filter(&is_changed/1)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/(?:import|alias)\s+([A-Z][\w.]*)/, line) do
        [_, name] -> [name]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  defp is_changed(line) do
    String.starts_with?(line, "+") || String.starts_with?(line, "-")
  end
end
