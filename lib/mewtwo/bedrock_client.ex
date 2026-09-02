defmodule Mewtwo.BedrockClient do
  @moduledoc """
  AWS Bedrock client for invoking Claude models

  Requires Bedrock token configured in:
  - BEDROCK_TOKEN (API token for authentication)
  - Optional: BEDROCK_MODEL_ID (default: anthropic.claude-3-5-sonnet-20241022-v2:0)
  """

  @doc """
  Invoke Claude via AWS Bedrock

  Returns: {:ok, response_text} or {:error, reason}
  """
  def invoke(prompt, timeout \\ 60_000) do
    token = System.get_env("BEDROCK_TOKEN")
    model_id = System.get_env("BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0")

    case token do
      nil ->
        {:error, "BEDROCK_TOKEN not configured"}

      token ->
        make_request(prompt, token, model_id, timeout)
    end
  end

  defp make_request(prompt, token, model_id, timeout) do
    url = "https://bedrock.us-east-1.amazonaws.com/model/#{model_id}/invoke"

    body = %{
      anthropic_version: "bedrock-2023-06-01",
      max_tokens: 4096,
      messages: [
        %{
          role: "user",
          content: prompt
        }
      ]
    }

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{token}"}
    ]

    with {:ok, response} <-
           Req.post(
             url,
             headers: headers,
             json: body,
             receive_timeout: timeout
           ) do
      handle_response(response)
    else
      {:error, reason} -> {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp handle_response(%Req.Response{status: 200, body: response_body}) when is_map(response_body) do
    case response_body do
      %{"content" => [%{"text" => text} | _]} ->
        {:ok, text}

      data ->
        {:error, "Unexpected response format: #{inspect(data)}"}
    end
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    body_str =
      case body do
        b when is_map(b) -> Jason.encode!(b)
        b when is_binary(b) -> b
        _ -> inspect(body)
      end

    {:error, "Bedrock returned #{status}: #{String.slice(body_str, 0..200)}"}
  end

  defp handle_response(response) do
    {:error, "Unexpected response format: #{inspect(response)}"}
  end
end
