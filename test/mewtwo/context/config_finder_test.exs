defmodule Mewtwo.Context.ConfigFinderTest do
  use ExUnit.Case
  alias Mewtwo.Context.ConfigFinder

  describe "find_context/1" do
    test "returns map with config_files and docs" do
      repo_path = File.cwd!()
      result = ConfigFinder.find_context(repo_path)

      assert is_map(result)
      assert Map.has_key?(result, :config_files)
      assert Map.has_key?(result, :docs)
      assert is_list(result.config_files)
      assert is_list(result.docs)
    end

    test "finds mix.exs" do
      repo_path = File.cwd!()
      result = ConfigFinder.find_context(repo_path)

      assert Enum.any?(result.config_files, &String.contains?(&1, "mix.exs"))
    end

    test "finds documentation files" do
      repo_path = File.cwd!()
      result = ConfigFinder.find_context(repo_path)

      # Should find at least README
      assert length(result.docs) > 0
    end

    test "returns file paths for config files" do
      repo_path = File.cwd!()
      result = ConfigFinder.find_context(repo_path)

      Enum.each(result.config_files, fn file ->
        assert is_binary(file)
        assert File.exists?(file)
      end)
    end

    test "returns {file, content} tuples for docs" do
      repo_path = File.cwd!()
      result = ConfigFinder.find_context(repo_path)

      Enum.each(result.docs, fn {file, content} ->
        assert is_binary(file)
        assert is_binary(content)
        assert String.length(content) > 0
      end)
    end

    test "handles missing config files gracefully" do
      repo_path = "/nonexistent/path"
      result = ConfigFinder.find_context(repo_path)

      assert result.config_files == []
      assert result.docs == []
    end
  end
end
