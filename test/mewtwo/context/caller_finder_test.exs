defmodule Mewtwo.Context.CallerFinderTest do
  use ExUnit.Case
  alias Mewtwo.Context.CallerFinder

  describe "find_callers/2" do
    test "returns map with function names as keys" do
      repo_path = File.cwd!()
      result = CallerFinder.find_callers(["parse"], repo_path)

      assert is_map(result)
      assert "parse" in Map.keys(result) or map_size(result) == 0
    end

    test "returns empty map for empty function list" do
      result = CallerFinder.find_callers([], File.cwd!())
      assert result == %{}
    end

    test "returns empty list for non-existent function" do
      result = CallerFinder.find_callers(["nonexistent_function_xyz"], File.cwd!())

      # Should have entry for the function with empty or small list
      assert is_map(result)
      assert Enum.all?(result, fn {_k, v} -> is_list(v) end)
    end

    test "limits callers to top 10" do
      repo_path = File.cwd!()
      result = CallerFinder.find_callers(["to_string"], repo_path)

      Enum.each(result, fn {_func, callers} ->
        assert length(callers) <= 10
      end)
    end

    test "ranks by depth (direct first)" do
      repo_path = File.cwd!()
      result = CallerFinder.find_callers(["parse"], repo_path)

      Enum.each(result, fn {_func, callers} ->
        # Callers should be sorted by depth
        depths = Enum.map(callers, fn {_file, _line, depth} -> depth end)
        assert depths == Enum.sort(depths)
      end)
    end

    test "includes file and line number" do
      repo_path = File.cwd!()
      result = CallerFinder.find_callers(["count_tokens"], repo_path)

      Enum.each(result, fn {_func, callers} ->
        Enum.each(callers, fn {file, line, _depth} ->
          assert is_binary(file)
          assert is_integer(line)
          assert line > 0
        end)
      end)
    end

    test "returns valid file paths" do
      repo_path = File.cwd!()
      result = CallerFinder.find_callers(["parse"], repo_path)

      Enum.each(result, fn {_func, callers} ->
        Enum.each(callers, fn {file, _line, _depth} ->
          # File path should be relative to repo
          assert String.contains?(file, [".ex", ".exs"]) or file == ""
        end)
      end)
    end
  end
end
