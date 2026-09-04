defmodule Mewtwo.Workers.ReviewWorker do
  @moduledoc """
  Runs a review for one PR: fetch → compress → context → agents → judge.

  Enqueued by `MewtwoWeb.WebhookController` when the `initial-review` label is
  added to a PR, or when a labelled PR is pushed to.

  Job args:

    * `"pr_id"`, `"repo"`, `"pr_number"` — required, identify the PR
    * `"agents"` — optional list of agent names (defaults to all five)
    * `"repo_path"` — optional local checkout used to resolve callers and
      tests. Without it the dynamic-context stage is skipped, since it greps
      the filesystem and a webhook job has no checkout.
    * `"publish"` — optional boolean overriding `:review, :post_to_github`.
      Set it to `false` to run a review without commenting on the PR.
    * `"installation_id"` — optional GitHub App installation, taken from the
      webhook payload. Without it the installation is looked up from the repo.

  The whole review — reads and the posted comments — acts as one identity,
  resolved once at the start: the GitHub App when it is configured, otherwise
  `GITHUB_TOKEN`.
  """

  use Oban.Worker, queue: :reviews, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Mewtwo.{Compression, Cost, DynamicContext, Judge, PRContext, Repo, Review}
  alias Phoenix.PubSub
  alias Mewtwo.Agents.Spawner
  alias Mewtwo.Findings.{AgentFinding, Finding}
  alias Mewtwo.Github.Poster
  alias Mewtwo.GithubApp

  @default_agents ["bugs", "perf", "security", "architecture", "readability"]

  # Retrying will not help: the PR is gone, we cannot see it, or it is too big.
  @permanent_errors [
    :not_found,
    :unauthorized,
    :diff_too_large,
    :unexpected_diff_body,
    # App auth: a missing key, an unreadable key, or an app that is not
    # installed on the repo. None of these change between attempts.
    :missing_config,
    :bad_private_key,
    :not_installed
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: args}) do
    started = System.monotonic_time(:millisecond)

    Logger.info("[review] start: #{args["repo"]}##{args["pr_number"]}")

    review = create_review(args, job_id)

    case run_pipeline(review, args) do
      {:ok, author, reviewer, metadata, auth} ->
        complete(review, args, author, reviewer, metadata, auth, started)

      # A rate limit clears on GitHub's schedule, not ours. Oban's default
      # backoff would spend all three attempts inside the same window.
      {:error, {:rate_limited, message, seconds}} ->
        snooze(review, message, seconds)

      {:error, reason} ->
        fail(review, reason, started)
    end
  end

  defp run_pipeline(review, args) do
    repo = args["repo"]
    pr_number = args["pr_number"]
    agents = Map.get(args, "agents") || @default_agents

    with stage(review, "auth"),
         {:ok, auth} <- authenticate(args),
         stage(review, "fetch"),
         {:ok, context} <- PRContext.fetch_with_diff(repo, pr_number, auth),
         stage(review, "compress"),
         {:ok, compressed, compression} <- compress(context),
         stage(review, "context"),
         fetched_context <- fetch_dynamic_context(compressed, args),
         stage(review, "agents"),
         {:ok, findings, agent_meta} <-
           run_agents(agents, compressed, context_items(fetched_context), review.id) do
      stage(review, "judge")
      Logger.info("[review] stage :judge start: judging #{length(findings)} raw findings")

      {author, reviewer, judge_meta} =
        Judge.judge(findings, gitleaks_findings(), total_agents: length(agents))

      metadata =
        Map.merge(judge_meta, %{
          agents: agents,
          usage: agent_meta.usage,
          # Per-agent tokens and latency are computed by the Spawner and were
          # previously discarded; the dashboard renders them on expand.
          per_agent: agent_meta.per_agent,
          agent_errors: agent_meta.errors,
          compression: compression,
          # Counts only: the fetched items are whole file excerpts, and this
          # map is persisted as JSON on the review row.
          context: context_counts(fetched_context)
        })

      {:ok, author, reviewer, metadata, auth}
    end
  end

  # Records which stage the run is on and tells the dashboard. Persisted rather
  # than telemetry-only so the stage survives a page reload and a node restart.
  defp stage(review, name) do
    review
    |> Review.changeset(%{stage: name, stage_started_at: DateTime.utc_now()})
    |> Repo.update!()

    announce(review.id, name)
  end

  defp announce(review_id, name) do
    PubSub.broadcast(Mewtwo.PubSub, "reviews", {:stage, review_id, name})
  end

  # One identity for the whole review. Resolved before the first request so a
  # misconfigured app fails the job immediately, rather than after five model
  # calls have been spent.
  defp authenticate(args) do
    case GithubApp.token_for(args["repo"], installation_id: args["installation_id"]) do
      {:ok, token} ->
        Logger.info("[review] stage :auth ok: acting as the GitHub App")
        {:ok, [token: token]}

      :no_app ->
        Logger.warning(
          "[review] stage :auth: no GitHub App configured, falling back to GITHUB_TOKEN — " <>
            "review comments will be authored by that account, not by the app"
        )

        {:ok, []}

      {:error, reason} ->
        Logger.error("[review] stage :auth FAILED: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp compress(%{diff: diff}) do
    {compressed, meta} = Compression.compress(diff, diff_token_budget())

    Logger.info(
      "[review] stage :compress ok: #{meta.original_tokens} -> #{meta.compressed_tokens} tokens " <>
        "(budget #{meta.token_budget})"
    )

    if meta.truncated_sections > 0 do
      Logger.warning(
        "[review] stage :compress dropped #{meta.truncated_sections} file(s) " <>
          "(#{meta.dropped_tokens} tokens) to fit the budget — the review does not cover them"
      )
    end

    if String.trim(compressed) == "" do
      # Compressing to nothing would send the agents an empty diff and produce
      # a confidently empty review.
      {:error, {:empty_compressed_diff, "compression produced an empty diff"}}
    else
      {:ok, compressed, meta}
    end
  end

  defp diff_token_budget do
    :mewtwo
    |> Application.get_env(:review, [])
    |> Keyword.get(:diff_token_budget, 100_000)
  end

  # Returns DynamicContext's full result, or nil when the stage did not run —
  # a distinction the summary comment reports, since a diff-only review is a
  # weaker review and the author deserves to know.
  defp fetch_dynamic_context(compressed, args) do
    case args["repo_path"] do
      nil ->
        Logger.warning(
          "[review] stage :context SKIPPED: no repo_path in job args, so callers " <>
            "and tests cannot be resolved. Agents will see the diff only."
        )

        nil

      repo_path ->
        result = DynamicContext.fetch(compressed, repo_path)

        Logger.info(
          "[review] stage :context ok: #{length(result.fetched_context)} items, " <>
            "#{result.tokens_used} tokens"
        )

        result
    end
  end

  defp context_items(nil), do: []
  defp context_items(%{fetched_context: fetched}), do: fetched

  defp context_counts(nil), do: nil

  defp context_counts(result) do
    %{
      fetched: length(result.fetched_context),
      skipped: length(result.skipped_items),
      tokens_used: result.tokens_used
    }
  end

  # G1-G3 are not built yet. Until then nothing can reach :high confidence,
  # since that tier requires an agent and a tool agreeing.
  defp gitleaks_findings do
    Logger.warning("[review] gitleaks not available: no tool findings to corroborate against")
    []
  end

  defp run_agents(agents, compressed, dynamic_context, review_id) do
    Logger.info("[review] stage :agents start: #{length(agents)} agents")

    {:ok, findings, meta} =
      Spawner.spawn_agents(agents, compressed, dynamic_context, gitleaks_findings(),
        review_id: review_id
      )

    log_per_agent(meta.per_agent)

    cond do
      findings == [] and length(meta.errors) == length(agents) ->
        {:error, {:all_agents_failed, Enum.join(meta.errors, "; ")}}

      meta.errors != [] ->
        # A partial result is still a review; a total failure is not.
        Logger.error(
          "[review] stage :agents partial: #{length(findings)} findings, " <>
            "#{length(meta.errors)} of #{length(agents)} agents failed"
        )

        {:ok, findings, meta}

      true ->
        Logger.info("[review] stage :agents ok: #{length(findings)} findings")
        {:ok, findings, meta}
    end
  end

  defp log_per_agent(per_agent) do
    Enum.each(per_agent, fn {agent, %{findings: count, usage: usage}} ->
      Logger.info("[review]   agent #{agent}: #{count} findings, #{Cost.describe(usage)}")
    end)
  end

  # Reuses an unfinished review for the same PR so a retried or snoozed job
  # does not leave a trail of duplicate rows.
  defp create_review(args, job_id) do
    review =
      case find_unfinished(args) do
        nil ->
          review =
            %Review{
              pr_id: args["pr_id"],
              repo: args["repo"],
              status: "pending",
              triggered_at: DateTime.utc_now()
            }
            |> Repo.insert!()

          Logger.info("[review] stage :record ok: review id=#{review.id}")

          review

        review ->
          Logger.info("[review] stage :record ok: resuming review id=#{review.id}")

          review
      end

    # The job id is what makes a zombie run distinguishable from a slow one:
    # the dashboard joins oban_jobs for liveness.
    review
    |> Review.changeset(%{
      stage: "record",
      stage_started_at: DateTime.utc_now(),
      oban_job_id: job_id
    })
    |> Repo.update!()
    |> tap(&announce(&1.id, "record"))
  end

  defp find_unfinished(args) do
    Repo.one(
      from review in Review,
        where:
          review.pr_id == ^args["pr_id"] and
            review.repo == ^args["repo"] and
            review.status in ["pending", "waiting"],
        order_by: [desc: review.triggered_at],
        limit: 1
    )
  end

  defp snooze(review, message, seconds) do
    Logger.warning(
      "[review] rate limited, snoozing #{seconds}s (~#{div(seconds, 60)}m) before retrying: " <>
        "#{String.slice(message, 0..120)}"
    )

    review
    |> Review.changeset(%{status: "waiting"})
    |> Repo.update!()

    # +5s so the retry lands after the window rolls over, not on the boundary.
    {:snooze, seconds + 5}
  end

  defp complete(review, args, author, reviewer, metadata, auth, started) do
    stage(review, "publish")

    # Published before the row is written so the outcome is recorded with the
    # review rather than needing a second update.
    metadata = Map.put(metadata, :publish, publish(args, author, reviewer, metadata, auth))

    usage = metadata.usage

    review
    |> Review.changeset(%{
      status: "complete",
      completed_at: DateTime.utc_now(),
      # Judge metadata rides along with the author findings; a dedicated
      # column would be cleaner but needs a migration.
      author_findings: findings_payload(author, metadata),
      reviewer_findings: findings_payload(reviewer, nil),
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      calls: usage.calls,
      cost_usd: frozen_cost(usage)
    })
    |> Repo.update!()

    # Rows for the metrics queries; the JSON above stays the archive of what
    # was posted. Never fails the run: the review is already recorded and the
    # dashboard reads its counts from the JSON.
    record_findings(review, author, reviewer)

    log_totals(review, author, reviewer, metadata, usage, started)
    announce(review.id, "done")

    :ok
  end

  defp record_findings(review, author, reviewer) do
    Finding.record(review.id, author, reviewer)
  rescue
    error ->
      Logger.error("[review] failed to record findings: #{Exception.message(error)}")
  end

  # nil, not 0.0, when rates are unset: a zero would read as a free review.
  defp frozen_cost(usage) do
    case Cost.estimate(usage) do
      {:ok, cost} -> cost
      :no_rates -> nil
    end
  end

  # A publishing failure does not fail the job. The findings are stored and
  # the pipeline that produced them cost five model calls; retrying to fix a
  # comment would re-run all of it, and a 403 from a missing `pull_requests:
  # write` permission will fail again anyway.
  defp publish(args, author, reviewer, metadata, auth) do
    cond do
      not publish?(args) ->
        Logger.info("[review] stage :publish SKIPPED: disabled by config or job args")
        %{status: "skipped", reason: "disabled"}

      is_nil(args["pr_number"]) ->
        Logger.warning("[review] stage :publish SKIPPED: no pr_number in job args")
        %{status: "skipped", reason: "no pr_number"}

      true ->
        do_publish(args, author, reviewer, metadata, auth)
    end
  end

  defp do_publish(args, author, reviewer, metadata, auth) do
    review = %{author_findings: author, reviewer_findings: reviewer, metadata: metadata}

    case Poster.post_review(args["repo"], args["pr_number"], review, auth) do
      {:ok, result} ->
        Logger.info(
          "[review] stage :publish ok: review #{result.review_id}, " <>
            "#{result.inline_comments} inline comments" <>
            if(result.fallback, do: " (inline comments folded into the summary)", else: "")
        )

        %{status: "posted", review_id: result.review_id, inline_comments: result.inline_comments}

      {:error, reason} ->
        Logger.error(
          "[review] stage :publish FAILED: #{inspect(reason)} — findings are stored but " <>
            "nothing was posted to the PR"
        )

        %{status: "failed", reason: inspect(reason)}
    end
  end

  defp publish?(args) do
    case Map.fetch(args, "publish") do
      {:ok, value} when is_boolean(value) -> value
      _ -> Application.get_env(:mewtwo, :review, []) |> Keyword.get(:post_to_github, true)
    end
  end

  defp log_totals(review, author, reviewer, metadata, usage, started) do
    Logger.info("[review] ===== review #{review.id} complete in #{elapsed(started)}ms =====")

    Logger.info(
      "[review] findings: #{length(author)} for the author, #{length(reviewer)} for reviewers"
    )

    Logger.info(
      "[review] judge: #{metadata.total_agents} agents, " <>
        "#{metadata.dedup_count} duplicates collapsed, " <>
        "#{metadata.gitleaks_findings_count} tool findings, " <>
        "#{round(metadata.tool_agreement_rate * 100)}% tool agreement"
    )

    Logger.info("[review] tokens: #{Cost.describe(usage)}")

    case Cost.estimate(usage) do
      {:ok, cost} ->
        Logger.info("[review] TOTAL COST: #{Cost.format_usd(cost)}")

      :no_rates ->
        Logger.warning(
          "[review] TOTAL COST: unavailable — set BEDROCK_INPUT_USD_PER_MTOK and " <>
            "BEDROCK_OUTPUT_USD_PER_MTOK (see https://aws.amazon.com/bedrock/pricing/)"
        )
    end
  end

  defp findings_payload(findings, metadata) do
    payload = %{
      "count" => length(findings),
      "findings" => Enum.map(findings, &AgentFinding.to_map/1)
    }

    if metadata, do: Map.put(payload, "metadata", stringify(metadata)), else: payload
  end

  defp stringify(metadata) do
    Map.new(metadata, fn
      {key, value} when is_map(value) -> {to_string(key), stringify(value)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp fail(review, reason, started) do
    Logger.error("[review] failed after #{elapsed(started)}ms: #{inspect(reason)}")

    review
    |> Review.changeset(%{
      status: "failed",
      completed_at: DateTime.utc_now(),
      # Without this the reason lives only in the log line above, so every
      # incident starts by shelling into logs.
      error: inspect(reason)
    })
    |> Repo.update!()

    announce(review.id, "done")

    if permanent?(reason) do
      # Cancel rather than retry: the outcome will not change.
      {:cancel, inspect(reason)}
    else
      {:error, inspect(reason)}
    end
  end

  defp permanent?({kind, _detail}), do: kind in @permanent_errors
  defp permanent?(_reason), do: false

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
