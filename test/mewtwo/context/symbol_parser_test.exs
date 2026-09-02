defmodule Mewtwo.Context.SymbolParserTest do
  use ExUnit.Case
  alias Mewtwo.Context.SymbolParser

  describe "parse/1" do
    test "extracts functions from diff" do
      diff = """
      @@ -1,5 +1,5 @@
      +def hello(name) do
      + "Hello"
      +end
      """

      result = SymbolParser.parse(diff)
      assert "hello" in result.functions
    end

    test "extracts private functions" do
      diff = "+defp private_func do"
      result = SymbolParser.parse(diff)
      assert "private_func" in result.functions
    end

    test "extracts modules" do
      diff = "+defmodule MyModule do"
      result = SymbolParser.parse(diff)
      assert "MyModule" in result.modules
    end

    test "extracts imports" do
      diff = "+import Enum"
      result = SymbolParser.parse(diff)
      assert "Enum" in result.imports
    end

    test "extracts aliases" do
      diff = "+alias Mewtwo.User"
      result = SymbolParser.parse(diff)
      assert "Mewtwo.User" in result.imports
    end

    test "ignores removed lines" do
      diff = "-def old_function do"
      result = SymbolParser.parse(diff)
      # Should extract even removed functions
      assert "old_function" in result.functions
    end

    test "ignores context lines" do
      diff = """
       def existing do
      + def new do
       end
      """

      result = SymbolParser.parse(diff)
      assert "new" in result.functions
      assert "existing" not in result.functions
    end

    test "handles multiple symbols" do
      diff = """
      +def func1 do
      +def func2 do
      +defmodule MyModule do
      +import Enum
      """

      result = SymbolParser.parse(diff)
      assert "func1" in result.functions
      assert "func2" in result.functions
      assert "MyModule" in result.modules
      assert "Enum" in result.imports
    end

    test "returns empty lists for empty diff" do
      result = SymbolParser.parse("")
      assert result.functions == []
      assert result.modules == []
      assert result.imports == []
    end

    test "deduplicates symbols" do
      diff = """
      +def hello do
      +def hello do
      """

      result = SymbolParser.parse(diff)
      assert Enum.count(result.functions, &(&1 == "hello")) == 1
    end
  end
end
