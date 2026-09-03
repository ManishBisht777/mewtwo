defmodule Mewtwo.BedrockClient do
  @moduledoc """
  AWS Bedrock client for invoking Claude models

  Authenticates with a Bedrock API key (long-lived bearer token, `ABSK...`)
  rather than SigV4 credentials, so requests are plain HTTP + `Authorization: Bearer`.

  Configuration (env vars, loaded from `.env` by :dotenv):
  - BEDROCK_TOKEN — required, the Bedrock API key
  - BEDROCK_MODEL_ID — inference profile ID (default: us.anthropic.claude-opus-4-5-20251101-v1:0)
  - BEDROCK_REGION — default: us-east-1

  Note that BEDROCK_MODEL_ID must be a full inference profile ID such as
  `us.anthropic.claude-opus-4-5-20251101-v1:0`. Bare model names and
  on-demand `anthropic.*` IDs are rejected by the invoke endpoint.
  """

  # Anthropic's wire format version on Bedrock. Not the same string as the
  # direct Anthropic API's `anthropic-version` header.
  @anthropic_version "bedrock-2023-05-31"

  @default_model_id "us.anthropic.claude-opus-4-5-20251101-v1:0"
  @default_region "us-east-1"
  @max_tokens 4096

  @doc """
  Invoke Claude via AWS Bedrock

  Returns: {:ok, response_text} or {:error, reason}
  """
  def invoke(prompt, timeout \\ 60_000) do
    case token() do
      nil ->
        {:error, "BEDROCK_TOKEN not configured"}

      token ->
        make_request(prompt, token, model_id(), region(), timeout)
    end
  end

  defp token do
    System.get_env("BEDROCK_TOKEN") || config(:token)
  end

  defp model_id do
    System.get_env("BEDROCK_MODEL_ID") || config(:model_id) || @default_model_id
  end

  defp region do
    System.get_env("BEDROCK_REGION") || config(:region) || @default_region
  end

  defp config(key) do
    :mewtwo
    |> Application.get_env(:bedrock, [])
    |> Keyword.get(key)
  end

  defp make_request(prompt, token, model_id, region, timeout) do
    # Invoke lives on the bedrock-runtime host; plain `bedrock.` is the
    # control plane and answers with UnknownOperationException.
    url =
      "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode_www_form(model_id)}/invoke"

    body = %{
      anthropic_version: @anthropic_version,
      max_tokens: @max_tokens,
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
