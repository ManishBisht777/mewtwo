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

  require Logger

  alias Mewtwo.{Compression, DynamicContext, Judge, PRContext, Repo, Review}
  alias Mewtwo.Agents.Spawner
  alias Mewtwo.Findings.AgentFinding

  @default_agents ["bugs", "perf", "security", "architecture", "readability"]

  # Retrying will not help: the PR is gone, we cannot see it, or it is too big.
  @permanent_errors [:not_found, :unauthorized, :diff_too_large, :unexpected_diff_body]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    repo = args["repo"]
    pr_number = args["pr_number"]
    started = System.monotonic_time(:millisecond)

    Logger.info("[review] start: #{repo}##{pr_number}")

    review = create_review(args)

    case run_pipeline(args) do
      {:ok, author, reviewer, metadata} ->
        complete(review, author, reviewer, metadata, started)

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
         {:ok, findings} <- run_agents(agents, compressed, dynamic_context) do
      {author, reviewer, metadata} =
        Judge.judge(findings, gitleaks_findings(), total_agents: length(agents))

      {:ok, author, reviewer, metadata}
    end
  end

  defp compress(%{diff: diff}) do
    {compressed, meta} = Compression.compress(diff, %{})

    Logger.info(
      "[review] stage :compress ok: #{meta.original_tokens} -> #{meta.compressed_tokens} tokens"
    )

    if String.trim(compressed) == "" do
      # Compressing to nothing would send the agents an empty diff and produce
      # a confidently empty review.
      {:error, {:empty_compressed_diff, "compression produced an empty diff"}}
    else
      {:ok, compressed}
    end
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
    case Spawner.spawn_agents(agents, compressed, dynamic_context, gitleaks_findings()) do
      {:ok, findings} ->
        Logger.info("[review] stage :agents ok: #{length(findings)} findings")
        {:ok, findings}

      {:ok, findings, errors: errors} ->
        Logger.error(
          "[review] stage :agents partial: #{length(findings)} findings, " <>
            "#{length(errors)} of #{length(agents)} agents failed"
        )

        # A partial result is still a review; a total failure is not.
        if findings == [] and length(errors) == length(agents) do
          {:error, {:all_agents_failed, Enum.join(errors, "; ")}}
        else
          {:ok, findings}
        end
    end
  end

  defp create_review(args) do
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
  end

  defp complete(review, author, reviewer, metadata, started) do
    review
    |> Review.changeset(%{
      status: "complete",
      completed_at: DateTime.utc_now(),
      # Judge metadata rides along with the author findings; a dedicated
      # column would be cleaner but needs a migration.
      author_findings: findings_payload(author, metadata),
      reviewer_findings: findings_payload(reviewer, nil)
    })
    |> Repo.update!()

    Logger.info(
      "[review] done in #{elapsed(started)}ms: #{length(author)} author + " <>
        "#{length(reviewer)} reviewer findings stored on review #{review.id}"
    )

    # :publish is not implemented — nothing is posted back to GitHub yet.
    Logger.warning("[review] stage :publish SKIPPED: no comment formatter (P1) yet")

    :ok
  end

  defp findings_payload(findings, metadata) do
    payload = %{
      "count" => length(findings),
      "findings" => Enum.map(findings, &AgentFinding.to_map/1)
    }

    if metadata, do: Map.put(payload, "metadata", stringify(metadata)), else: payload
  end

  defp stringify(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
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
