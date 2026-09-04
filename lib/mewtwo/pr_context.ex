defmodule Mewtwo.PRContext do
  @moduledoc "Fetches a PR's unified diff for analysis"

  require Logger

  alias Mewtwo.GithubClient
  alias Mewtwo.TokenCounter

  # Only rejects diffs so large that fetching and compressing them is a waste;
  # anything smaller is trimmed to budget by Mewtwo.Compression.
  @max_context_tokens 2_000_000

  @doc """
  Fetch the PR's unified diff.

  `opts` are passed to `Mewtwo.GithubClient` — notably `:token`, so a review
  reads the PR as the same identity that will comment on it.
  """
  def fetch_with_diff(repo, pr_number, opts \\ []) do
    Logger.info("Fetching PR diff: #{repo}##{pr_number}")

    with {:ok, diff} <- fetch_diff(repo, pr_number, opts) do
      diff_tokens = estimate_diff_tokens(diff)

      Logger.info("PR context: ~#{diff_tokens} diff tokens")

      if diff_tokens > @max_context_tokens do
        {:error,
         {:diff_too_large,
          "PR diff too large (#{diff_tokens} > #{@max_context_tokens} tokens). Consider splitting."}}
      else
        {:ok, %{diff: diff}}
      end
    end
  end

  defp fetch_diff(repo, pr_number, opts) do
    # The .diff media type returns a unified diff; .raw / the default JSON type
    # return the PR object instead, which cannot be compressed downstream.
    case GithubClient.get(
           "/repos/#{repo}/pulls/#{pr_number}",
           [headers: [{"Accept", "application/vnd.github.v3.diff"}]] ++ opts
         ) do
      {:ok, diff_text} when is_binary(diff_text) ->
        {:ok, diff_text}

      # Never pass a non-diff body through as {:ok, _}: it would satisfy the
      # `with` above and set context.diff to a map.
      {:ok, other} ->
        {:error,
         {:unexpected_diff_body,
          "expected a unified diff, got #{inspect(other, printable_limit: 200)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Counting lines (the previous approach) undercounts a minified or lockfile
  # diff by more than an order of magnitude, so the ceiling never fired.
  defp estimate_diff_tokens(diff_text) when is_binary(diff_text) do
    TokenCounter.count_tokens(diff_text, :code)
  end
end
