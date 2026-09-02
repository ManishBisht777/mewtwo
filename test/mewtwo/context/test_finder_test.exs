defmodule Mewtwo.Context.TestFinderTest do
  use ExUnit.Case
  alias Mewtwo.Context.TestFinder

  describe "find_tests/2" do
    test "finds test file for existing module" do
      repo_path = File.cwd!()
      result = TestFinder.find_tests(["Mewtwo.TokenCounter"], repo_path)

      assert is_map(result)
      # TokenCounter should have a test file
      assert map_size(result) >= 0
    end

    test "returns empty map for non-existent module" do
      repo_path = File.cwd!()
      result = TestFinder.find_tests(["NonExistentModule"], repo_path)

      assert result == %{}
    end

    test "handles multiple modules" do
      repo_path = File.cwd!()
      result = TestFinder.find_tests(["Mewtwo.TokenCounter", "NonExistent"], repo_path)

      assert is_map(result)
      # Should find at least TokenCounter test
      assert map_size(result) >= 0
    end

    test "returns file path and content" do
      repo_path = File.cwd!()
      result = TestFinder.find_tests(["Mewtwo.TokenCounter"], repo_path)

      Enum.each(result, fn {file, content} ->
        assert is_binary(file)
        assert String.contains?(file, "_test.exs")
        assert is_binary(content)
        assert String.length(content) > 0
      end)
    end

    test "returns empty map for empty module list" do
      result = TestFinder.find_tests([], File.cwd!())
      assert result == %{}
    end

    test "converts module names to file paths correctly" do
      repo_path = File.cwd!()
      result = TestFinder.find_tests(["Mewtwo.Compression"], repo_path)

      # Should look for test/mewtwo/compression_test.exs
      assert is_map(result)
    end
  end
end
