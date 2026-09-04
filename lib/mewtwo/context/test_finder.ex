defmodule Mewtwo.Context.TestFinder do
  @doc "Find test files for changed modules"
  def find_tests(modules, repo_path) do
    modules
    |> Enum.flat_map(fn module ->
      test_file = test_path(module, repo_path)

      if File.exists?(test_file) do
        [{test_file, File.read!(test_file)}]
      else
        []
      end
    end)
    |> Enum.into(%{})
  end

  defp test_path(module_name, repo_path) do
    path_parts =
      module_name
      |> String.downcase()
      |> String.split(".")
      |> Enum.join("/")

    Path.join([repo_path, "test", path_parts <> "_test.exs"])
  end
end
