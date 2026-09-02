defmodule Mewtwo.Context.ConfigFinder do
  @doc "Find config and documentation files"
  def find_context(repo_path) do
    %{
      config_files: find_config_files(repo_path),
      docs: find_documentation(repo_path)
    }
  end

  defp find_config_files(repo_path) do
    config_patterns = [
      ".env",
      "config/config.exs",
      "config/dev.exs",
      "config/prod.exs",
      "config/test.exs",
      "mix.exs",
      "mix.lock"
    ]

    config_patterns
    |> Enum.map(&Path.join(repo_path, &1))
    |> Enum.filter(&File.exists?/1)
  end

  defp find_documentation(repo_path) do
    doc_files = [
      "README.md",
      "CONTRIBUTING.md",
      "ARCHITECTURE.md",
      "CONTEXT.md",
      "ADR.md"
    ]

    doc_files
    |> Enum.map(&Path.join(repo_path, &1))
    |> Enum.filter(&File.exists?/1)
    |> Enum.map(fn file ->
      content = File.read!(file)
      {file, content}
    end)
  end
end
