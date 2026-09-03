defmodule Mewtwo.BedrockClientTest do
  use ExUnit.Case
  alias Mewtwo.BedrockClient

  # Runs the given function with BEDROCK_TOKEN unset, so `invoke/2` short-circuits
  # before making a (billed) network call.
  defp without_token(fun) do
    old_token = System.get_env("BEDROCK_TOKEN")

    try do
      System.delete_env("BEDROCK_TOKEN")
      fun.()
    after
      if old_token, do: System.put_env("BEDROCK_TOKEN", old_token)
    end
  end

  describe "invoke/2" do
    test "returns error when BEDROCK_TOKEN not configured" do
      without_token(fn ->
        assert {:error, reason} = BedrockClient.invoke("test prompt")
        assert String.contains?(reason, "BEDROCK_TOKEN not configured")
      end)
    end

    test "accepts an explicit timeout" do
      without_token(fn ->
        assert {:error, _} = BedrockClient.invoke("test", 5_000)
      end)
    end

    test "has a default timeout" do
      without_token(fn ->
        assert {:error, _} = BedrockClient.invoke("test prompt")
      end)
    end

    @tag :bedrock
    test "invokes Claude and returns the response text with usage" do
      assert {:ok, text, usage} = BedrockClient.invoke("Reply with exactly: OK", 30_000)
      assert is_binary(text)
      assert text =~ "OK"

      assert usage.input_tokens > 0
      assert usage.output_tokens > 0
      assert usage.calls == 1
    end
  end
end
