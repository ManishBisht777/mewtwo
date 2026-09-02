defmodule Mewtwo.Context.TestFinder do
  @doc "Find test files for changed modules"
  def find_tests(modules, repo_path) do
    modules
    |> Enum.map(fn module ->
      test_file = find_test_file(module, repo_path)

      if test_file && File.exists?(test_file) do
        content = File.read!(test_file)
        {test_file, content}
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp find_test_file(module_name, repo_path) do
    path_parts =
      module_name
      |> String.downcase()
      |> String.split(".")
      |> Enum.join("/")

    test_file = Path.join([repo_path, "test", path_parts <> "_test.exs"])

    if File.exists?(test_file) do
      test_file
    else
      nil
    end
  end
end
