defmodule Mewtwo.PRContext do
  @moduledoc "Fetches and organizes PR context for analysis"

  require Logger

  alias Mewtwo.GithubClient

  # Token budgets (approximate tokens per item)
  @max_context_tokens 180_000
  @avg_tokens_per_file 500
  @avg_tokens_per_diff_line 1

  def fetch(repo, pr_number) do
    Logger.info("Fetching PR context: #{repo}##{pr_number}")

    with {:ok, pr} <- fetch_pr(repo, pr_number),
         {:ok, files} <- fetch_changed_files(repo, pr_number),
         {:ok, commits} <- fetch_commits(repo, pr_number) do
      {:ok,
       %{
         pr: pr,
         files: files,
         commits: commits,
         fetched_at: DateTime.utc_now()
       }}
    else
      error ->
        Logger.error("Failed to fetch PR context: #{inspect(error)}")
        error
    end
  end

  def fetch_with_diff(repo, pr_number) do
    with {:ok, context} <- fetch(repo, pr_number),
         {:ok, diff} <- fetch_diff(repo, pr_number) do
      diff_tokens = estimate_diff_tokens(diff)
      file_tokens = length(context.files) * @avg_tokens_per_file

      Logger.info(
        "PR context: #{file_tokens} file tokens, ~#{diff_tokens} diff tokens, #{file_tokens + diff_tokens} total estimate"
      )

      if file_tokens + diff_tokens > @max_context_tokens do
        {:error,
         {:diff_too_large,
          "PR diff too large (#{file_tokens + diff_tokens} > #{@max_context_tokens} tokens). Consider splitting."}}
      else
        {:ok, Map.put(context, :diff, diff)}
      end
    else
      error -> error
    end
  end

  defp fetch_pr(repo, pr_number) do
    GithubClient.get("/repos/#{repo}/pulls/#{pr_number}")
  end

  defp fetch_changed_files(repo, pr_number) do
    GithubClient.get_paginated("/repos/#{repo}/pulls/#{pr_number}/files?per_page=100")
  end

  defp fetch_commits(repo, pr_number) do
    GithubClient.get_paginated("/repos/#{repo}/pulls/#{pr_number}/commits?per_page=100")
  end

  defp fetch_diff(repo, pr_number) do
    # The .diff media type returns a unified diff; .raw / the default JSON type
    # return the PR object instead, which cannot be compressed downstream.
    case GithubClient.get("/repos/#{repo}/pulls/#{pr_number}",
           headers: [{"Accept", "application/vnd.github.v3.diff"}]
         ) do
      {:ok, diff_text} when is_binary(diff_text) ->
        {:ok, diff_text}

      # Never pass a non-diff body through as {:ok, _}: it would satisfy the
      # `with` above and set context.diff to a map.
      {:ok, other} ->
        {:error, {:unexpected_diff_body, "expected a unified diff, got #{inspect(other, printable_limit: 200)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp estimate_diff_tokens(diff_text) when is_binary(diff_text) do
    lines = String.split(diff_text, "\n")
    length(lines) * @avg_tokens_per_diff_line
  end
end
