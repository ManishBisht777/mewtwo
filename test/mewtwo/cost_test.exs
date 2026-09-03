defmodule Mewtwo.CostTest do
  use ExUnit.Case, async: false

  alias Mewtwo.Cost

  defp usage(input, output, calls \\ 1) do
    %{input_tokens: input, output_tokens: output, calls: calls}
  end

  defp with_rates(input, output, fun) do
    old = Application.get_env(:mewtwo, :bedrock_pricing)

    try do
      Application.put_env(:mewtwo, :bedrock_pricing,
        input_usd_per_mtok: input,
        output_usd_per_mtok: output
      )

      fun.()
    after
      if old,
        do: Application.put_env(:mewtwo, :bedrock_pricing, old),
        else: Application.delete_env(:mewtwo, :bedrock_pricing)
    end
  end

  describe "usage_from_response/1" do
    test "reads token counts out of a Bedrock response body" do
      body = %{"usage" => %{"input_tokens" => 5897, "output_tokens" => 357}}

      assert Cost.usage_from_response(body) == usage(5897, 357)
    end

    test "counts the call even when usage is absent" do
      assert Cost.usage_from_response(%{"content" => []}) == usage(0, 0, 1)
    end

    test "tolerates a partial usage object" do
      assert Cost.usage_from_response(%{"usage" => %{"input_tokens" => 10}}) == usage(10, 0)
    end
  end

  describe "add/2 and total/1" do
    test "sums usage" do
      assert Cost.add(usage(10, 1), usage(20, 2)) == usage(30, 3, 2)
    end

    test "totals a list" do
      assert Cost.total([usage(10, 1), usage(20, 2), usage(30, 3)]) == usage(60, 6, 3)
    end

    test "totals an empty list to zero" do
      assert Cost.total([]) == Cost.zero()
      assert Cost.zero() == usage(0, 0, 0)
    end
  end

  describe "estimate/1" do
    test "prices usage from the configured rates" do
      # 1M in at $5 + 1M out at $25 = $30
      with_rates(5.0, 25.0, fn ->
        assert {:ok, cost} = Cost.estimate(usage(1_000_000, 1_000_000))
        assert_in_delta cost, 30.0, 0.000001
      end)
    end

    test "scales sub-million token counts" do
      with_rates(5.0, 25.0, fn ->
        assert {:ok, cost} = Cost.estimate(usage(5897, 357))
        # 5897/1M * 5 + 357/1M * 25
        assert_in_delta cost, 0.0294850 + 0.0089250, 0.000001
      end)
    end

    test "accepts rates given as strings, as env vars supply them" do
      with_rates("5.0", "25.0", fn ->
        assert {:ok, cost} = Cost.estimate(usage(1_000_000, 0))
        assert_in_delta cost, 5.0, 0.000001
      end)
    end

    test "reports :no_rates rather than guessing when pricing is unset" do
      # Bedrock is partner-priced; a wrong number is worse than no number.
      with_rates(nil, nil, fn ->
        assert Cost.estimate(usage(1000, 100)) == :no_rates
      end)
    end

    test "reports :no_rates when only one side is configured" do
      with_rates(5.0, nil, fn -> assert Cost.estimate(usage(1000, 100)) == :no_rates end)
      with_rates(nil, 25.0, fn -> assert Cost.estimate(usage(1000, 100)) == :no_rates end)
    end

    test "reports :no_rates for an unparseable rate" do
      with_rates("free", "25.0", fn -> assert Cost.estimate(usage(1, 1)) == :no_rates end)
    end
  end

  describe "describe/1" do
    test "includes cost when rates are configured" do
      with_rates(5.0, 25.0, fn ->
        described = Cost.describe(usage(5897, 357))

        assert described =~ "5,897 in / 357 out tokens"
        assert described =~ "over 1 call"
        assert described =~ "$0."
      end)
    end

    test "says so plainly when cost is unavailable" do
      with_rates(nil, nil, fn ->
        described = Cost.describe(usage(5897, 357))

        assert described =~ "5,897 in / 357 out tokens"
        assert described =~ "cost unavailable"
      end)
    end

    test "pluralises the call count" do
      with_rates(nil, nil, fn ->
        assert Cost.describe(usage(1, 1, 1)) =~ "over 1 call,"
        assert Cost.describe(usage(1, 1, 5)) =~ "over 5 calls,"
      end)
    end

    test "groups thousands for readability" do
      with_rates(nil, nil, fn ->
        assert Cost.describe(usage(1_234_567, 89)) =~ "1,234,567 in / 89 out"
      end)
    end
  end

  describe "format_usd/1" do
    test "keeps small amounts legible with extra precision" do
      assert Cost.format_usd(0.00123) == "$0.00123"
    end

    test "uses four decimals for larger amounts" do
      assert Cost.format_usd(1.23456789) == "$1.2346"
    end
  end
end
