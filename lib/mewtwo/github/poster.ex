defmodule Mewtwo.Github.Poster do
  @moduledoc """
  P3 — publish a finished review to the pull request

  Posts as **one** pull request review (`POST /pulls/:n/reviews`) carrying the
  summary as its body and the author findings as inline comments, rather than
  as N separate comment requests. One request means one notification for the
  author instead of a dozen, and it cannot half-post: either the whole review
  lands or nothing does.

  `event: "COMMENT"` — never `REQUEST_CHANGES`. A bot that blocks merges on
  unverified model output gets its permissions revoked within a week.

  Findings the agents reported over and over across files are not commented on
  individually: `Mewtwo.Github.FindingGrouper` collapses them into one summary
  entry listing every location. Five comments repeating one sentence read as a
  broken bot, not as five problems.

  ## The 422 fallback

  GitHub rejects an inline comment whose line is not part of the diff, and it
  rejects the *entire* review when it does. Agents do occasionally report a
  line just outside a hunk, so a rejected review is retried once with the
  inline comments folded into the summary body. A slightly worse review beats
  a review nobody sees.
  """

  require Logger

  alias Mewtwo.Github.{CommentFormatter, FindingGrouper, SummaryFormatter}
  alias Mewtwo.GithubClient

  # How many findings the 422 fallback lists in the summary body.
  @max_fallback_items 50

  @doc """
  Post a review to `repo`'s PR `pr_number`

  `metadata` is passed straight to `Mewtwo.Github.SummaryFormatter.format/3`.

  Options:

    * `:request_opts` — passed through to `Mewtwo.GithubClient.post/3`, for
      tests that serve the request with a plug

  Returns `{:ok, result}` where result is:

    * `:review_id` — GitHub's id for the posted review
    * `:inline_comments` — how many inline comments it carries
    * `:fallback` — true when inline comments had to be folded into the body

  GitHub's review endpoint answers with the review, not with per-comment ids,
  so individual comment ids are not available without a further request.

  Errors are `GithubClient`'s: `{:unauthorized, msg}`, `{:not_found, msg}`,
  `{:rate_limited, msg, seconds}`, `{:http_error, status, msg}`. Callers should
  treat `:rate_limited` as retriable and the rest as terminal.
  """
  def post_review(
        repo,
        pr_number,
        author_findings,
        reviewer_findings,
        metadata \\ %{},
        opts \\ []
      ) do
    if GithubClient.authenticated?() do
      do_post(repo, pr_number, author_findings, reviewer_findings, metadata, opts)
    else
      # Anonymous requests can read a public repo but never write to one, so
      # this would otherwise surface as an unexplained 401.
      Logger.error("[publish] no GITHUB_TOKEN set, so the review cannot be posted")

      {:error, {:unauthenticated, "posting a review requires GITHUB_TOKEN"}}
    end
  end

  defp do_post(repo, pr_number, author_findings, reviewer_findings, metadata, opts) do
    summary = SummaryFormatter.format(author_findings, reviewer_findings, metadata)

    # The summary carries the recurring patterns; only the one-off findings
    # earn a comment of their own. Both sides derive the same split from the
    # same findings.
    {patterns, individual} = FindingGrouper.partition(author_findings)
    comments = CommentFormatter.to_comments(individual)

    Logger.info(
      "[publish] start: #{repo}##{pr_number}, #{length(comments)} inline comments, " <>
        "#{length(patterns)} grouped pattern(s), #{byte_size(summary)}-byte summary"
    )

    case submit(repo, pr_number, summary, comments, opts) do
      {:ok, review} ->
        result = %{
          review_id: review_id(review),
          inline_comments: length(comments),
          fallback: false
        }

        Logger.info(
          "[publish] ok: review #{result.review_id} with #{result.inline_comments} inline comments"
        )

        {:ok, result}

      # Unprocessable means GitHub understood the request and refused it —
      # for a review body that is almost always a line outside the diff.
      {:error, {:http_error, 422, message}} when comments != [] ->
        Logger.warning(
          "[publish] GitHub rejected #{length(comments)} inline comments (422: " <>
            "#{String.slice(message, 0..160)}); retrying with them in the summary"
        )

        post_without_inline(repo, pr_number, summary, individual, opts)

      {:error, reason} = error ->
        Logger.error("[publish] failed: #{inspect(reason)}")
        error
    end
  end

  defp post_without_inline(repo, pr_number, summary, individual, opts) do
    body = summary <> "\n\n" <> rejected_section(individual)

    case submit(repo, pr_number, body, [], opts) do
      {:ok, review} ->
        result = %{review_id: review_id(review), inline_comments: 0, fallback: true}

        Logger.info("[publish] ok via fallback: review #{result.review_id}, no inline comments")

        {:ok, result}

      {:error, reason} = error ->
        Logger.error("[publish] fallback also failed: #{inspect(reason)}")
        error
    end
  end

  # Only the findings that were meant to be inline comments; ones with no
  # usable line, and the recurring patterns, are already in the summary.
  defp rejected_section(individual) do
    rejected = Enum.filter(individual, &CommentFormatter.commentable?/1)

    # A comment body is capped at 65,536 characters, so a review with hundreds
    # of findings cannot list them all here. The rest are on the review record.
    shown = Enum.take(rejected, @max_fallback_items)
    items = Enum.map_join(shown, "\n", &CommentFormatter.format_line_item/1)

    overflow =
      case length(rejected) - length(shown) do
        0 -> ""
        n -> "\n\n…and #{n} more on the review record."
      end

    """
    ---

    **Findings for you.** GitHub would not accept these as inline comments —
    their lines fall outside this PR's diff.

    #{items}#{overflow}
    """
    |> String.trim()
  end

  defp submit(repo, pr_number, body, comments, opts) do
    payload = %{event: "COMMENT", body: body}
    payload = if comments == [], do: payload, else: Map.put(payload, :comments, comments)

    GithubClient.post(
      "/repos/#{repo}/pulls/#{pr_number}/reviews",
      payload,
      Keyword.get(opts, :request_opts, [])
    )
  end

  defp review_id(%{"id" => id}), do: id
  defp review_id(_body), do: nil
end
