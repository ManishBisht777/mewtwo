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
  """

  use Oban.Worker, queue: :reviews, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Mewtwo.{Compression, Cost, DynamicContext, Judge, PRContext, Repo, Review}
  alias Mewtwo.Agents.Spawner
  alias Mewtwo.Findings.AgentFinding

  @default_agents ["bugs", "perf", "security", "architecture", "readability"]

  # Retrying will not help: the PR is gone, we cannot see it, or it is too big.
  @permanent_errors [:not_found, :unauthorized, :diff_too_large, :unexpected_diff_body]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    started = System.monotonic_time(:millisecond)

    Logger.info("[review] start: #{args["repo"]}##{args["pr_number"]}")

    review = create_review(args)

    case run_pipeline(args) do
      {:ok, author, reviewer, metadata, usage} ->
        complete(review, author, reviewer, metadata, usage, started)

      # A rate limit clears on GitHub's schedule, not ours. Oban's default
      # backoff would spend all three attempts inside the same window.
      {:error, {:rate_limited, message, seconds}} ->
        snooze(review, message, seconds)

      {:error, reason} ->
        fail(review, reason, started)
    end
  end

  defp run_pipeline(args) do
    repo = args["repo"]
    pr_number = args["pr_number"]
    agents = Map.get(args, "agents") || @default_agents

    with {:ok, context} <- PRContext.fetch_with_diff(repo, pr_number),
         {:ok, compressed} <- compress(context),
         dynamic_context <- fetch_dynamic_context(compressed, args),
         {:ok, findings, agent_meta} <- run_agents(agents, compressed, dynamic_context) do
      Logger.info("[review] stage :judge start: judging #{length(findings)} raw findings")

      {author, reviewer, metadata} =
        Judge.judge(findings, gitleaks_findings(), total_agents: length(agents))

      {:ok, author, reviewer, metadata, agent_meta.usage}
    end
  end

  defp compress(%{diff: diff}) do
    {compressed, meta} = Compression.compress(diff, %{}, diff_token_budget())

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
      {:ok, compressed}
    end
  end

  defp diff_token_budget do
    :mewtwo
    |> Application.get_env(:review, [])
    |> Keyword.get(:diff_token_budget, 100_000)
  end

  defp fetch_dynamic_context(compressed, args) do
    case args["repo_path"] do
      nil ->
        Logger.warning(
          "[review] stage :context SKIPPED: no repo_path in job args, so callers " <>
            "and tests cannot be resolved. Agents will see the diff only."
        )

        []

      repo_path ->
        result = DynamicContext.fetch(compressed, repo_path)

        Logger.info(
          "[review] stage :context ok: #{length(result.fetched_context)} items, " <>
            "#{result.tokens_used} tokens"
        )

        result.fetched_context
    end
  end

  # G1-G3 are not built yet. Until then nothing can reach :high confidence,
  # since that tier requires an agent and a tool agreeing.
  defp gitleaks_findings do
    Logger.warning("[review] gitleaks not available: no tool findings to corroborate against")
    []
  end

  defp run_agents(agents, compressed, dynamic_context) do
    Logger.info("[review] stage :agents start: #{length(agents)} agents")

    {:ok, findings, meta} =
      Spawner.spawn_agents(agents, compressed, dynamic_context, gitleaks_findings())

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
  defp create_review(args) do
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

  defp complete(review, author, reviewer, metadata, usage, started) do
    review
    |> Review.changeset(%{
      status: "complete",
      completed_at: DateTime.utc_now(),
      # Judge metadata rides along with the author findings; a dedicated
      # column would be cleaner but needs a migration.
      author_findings: findings_payload(author, Map.put(metadata, :usage, usage)),
      reviewer_findings: findings_payload(reviewer, nil)
    })
    |> Repo.update!()

    # :publish is not implemented — nothing is posted back to GitHub yet.
    Logger.warning("[review] stage :publish SKIPPED: no comment formatter (P1) yet")

    log_totals(review, author, reviewer, metadata, usage, started)

    :ok
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
    |> Review.changeset(%{status: "failed", completed_at: DateTime.utc_now()})
    |> Repo.update!()

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
