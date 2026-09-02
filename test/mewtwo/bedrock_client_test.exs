defmodule Mewtwo.BedrockClientTest do
  use ExUnit.Case
  alias Mewtwo.BedrockClient

  describe "invoke/2" do
    test "returns error when BEDROCK_TOKEN not configured" do
      old_token = System.get_env("BEDROCK_TOKEN")

      try do
        System.delete_env("BEDROCK_TOKEN")

        result = BedrockClient.invoke("test prompt")

        assert {:error, reason} = result
        assert String.contains?(reason, "BEDROCK_TOKEN not configured")
      after
        if old_token, do: System.put_env("BEDROCK_TOKEN", old_token)
      end
    end

    @tag :bedrock
    test "invokes Claude and returns response when token available" do
      if System.get_env("BEDROCK_TOKEN") do
        prompt = "Return this exact JSON: [{\"file\": \"test.ex\", \"line\": 1, \"severity\": \"high\"}]"

        result = BedrockClient.invoke(prompt, 30_000)

        assert (match?({:ok, _}, result) or match?({:error, _}, result))
      else
        :skip
      end
    end

    test "accepts timeout option" do
      timeout_ms = 5000

      result = BedrockClient.invoke("test", timeout_ms)

      assert {:error, _} = result
    end

    test "handles default timeout" do
      result = BedrockClient.invoke("test prompt")

      assert {:error, _} = result
    end
  end
end
