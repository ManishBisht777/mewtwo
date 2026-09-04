defmodule Mewtwo.Context.SymbolParser do
  @doc "Extract changed symbols from diff"
  def parse(diff_string) do
    lines = String.split(diff_string, "\n")

    %{
      functions: extract(lines, ~r/def[p]?\s+(\w+)/),
      modules: extract(lines, ~r/defmodule\s+([A-Z]\w*)/),
      imports: extract(lines, ~r/(?:import|alias)\s+([A-Z][\w.]*)/)
    }
  end

  defp extract(lines, regex) do
    lines
    |> Enum.filter(&is_changed/1)
    |> Enum.flat_map(fn line ->
      case Regex.run(regex, line) do
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
