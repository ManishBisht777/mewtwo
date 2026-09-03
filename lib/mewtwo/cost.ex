defmodule Mewtwo.Cost do
  @moduledoc """
  Token accounting and cost estimation for model calls.

  Token counts come straight from the Bedrock response and are always exact.
  Dollar figures depend on per-token rates, which are **not** hardcoded:
  Bedrock is partner-operated and priced separately from Anthropic's
  first-party API, so the rates are configuration.

  Set them in `.env`:

      BEDROCK_INPUT_USD_PER_MTOK=...
      BEDROCK_OUTPUT_USD_PER_MTOK=...

  from https://aws.amazon.com/bedrock/pricing/ for the model in
  `BEDROCK_MODEL_ID`. Until they are set, token counts are reported and cost
  is reported as unavailable rather than as a wrong number.
  """

  @empty %{input_tokens: 0, output_tokens: 0, calls: 0}

  @doc "Zero usage, for use as an accumulator seed"
  def zero, do: @empty

  @doc """
  Build a usage map from a Bedrock response body's `usage` object
  """
  def usage_from_response(%{"usage" => usage}) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      calls: 1
    }
  end

  def usage_from_response(_body), do: %{@empty | calls: 1}

  @doc "Sum two usage maps"
  def add(a, b) do
    %{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      calls: a.calls + b.calls
    }
  end

  @doc "Sum a list of usage maps"
  def total(usages), do: Enum.reduce(usages, zero(), &add(&2, &1))

  @doc """
  Estimate the cost of some usage in USD

  Returns `{:ok, usd}`, or `:no_rates` when pricing is not configured.
  """
  def estimate(usage) do
    with {:ok, input_rate} <- rate(:input_usd_per_mtok),
         {:ok, output_rate} <- rate(:output_usd_per_mtok) do
      cost =
        usage.input_tokens / 1_000_000 * input_rate +
          usage.output_tokens / 1_000_000 * output_rate

      {:ok, cost}
    else
      :error -> :no_rates
    end
  end

  @doc """
  Human-readable usage summary, with cost when rates are configured

  e.g. `"5,897 in / 357 out tokens over 1 call, $0.0387"`
  """
  def describe(usage) do
    base =
      "#{number(usage.input_tokens)} in / #{number(usage.output_tokens)} out tokens " <>
        "over #{usage.calls} call#{if usage.calls == 1, do: "", else: "s"}"

    case estimate(usage) do
      {:ok, cost} -> base <> ", #{format_usd(cost)}"
      :no_rates -> base <> ", cost unavailable (BEDROCK_*_USD_PER_MTOK not set)"
    end
  end

  @doc "Format a USD amount, keeping small amounts legible"
  def format_usd(cost) when cost < 0.01, do: "$#{:erlang.float_to_binary(cost, decimals: 5)}"
  def format_usd(cost), do: "$#{:erlang.float_to_binary(cost, decimals: 4)}"

  defp rate(key) do
    :mewtwo
    |> Application.get_env(:bedrock_pricing, [])
    |> Keyword.get(key)
    |> parse_rate()
  end

  defp parse_rate(nil), do: :error
  defp parse_rate(rate) when is_number(rate) and rate >= 0, do: {:ok, rate}

  defp parse_rate(rate) when is_binary(rate) do
    case Float.parse(String.trim(rate)) do
      {value, _} when value >= 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_rate(_), do: :error

  # 5897 -> "5,897"
  defp number(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
