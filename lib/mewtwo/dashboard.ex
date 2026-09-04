defmodule Mewtwo.Dashboard do
  @moduledoc """
  Aggregate queries behind `MewtwoWeb.DashboardLive`.

  The LiveView only renders; the windowing, the Oban join and the sparkline
  scaling live here because they are the parts that can actually be wrong, and
  they are far cheaper to assert as plain functions than through
  `LiveViewTest`.

  Two sources of truth, deliberately: Oban's job state says whether a run is
  *alive*, the review row says what it was *doing*. A node that dies mid-run
  leaves a row stuck on `pending` forever, so trusting the row alone would
  render zombies as "running" indefinitely.
  """

  import Ecto.Query

  alias Mewtwo.{Repo, Review}
  alias Mewtwo.Findings.Finding

  @window_days 7
  @recent_limit 25
  # ponytail: fixed window; add a period toggle when you actually reach for one

  @doc "Pipeline stages in order, as written by `ReviewWorker`"
  def stages, do: ~w(record auth fetch compress context agents judge publish)

  # Oban states that mean the job will still run, or is running right now.
  @live_states ~w(available scheduled retryable executing)

  @doc """
  Runs that have not finished, newest first.

  Each row carries `:liveness` — `:running` when Oban still has a live job for
  it, `:stalled` when the job is gone, discarded or already completed while
  the review row was left unfinished.
  """
  def in_flight do
    Repo.all(
      from r in Review,
        left_join: j in Oban.Job,
        on: j.id == r.oban_job_id,
        where: r.status in ["pending", "waiting"],
        order_by: [desc: r.triggered_at],
        select: %{
          id: r.id,
          repo: r.repo,
          pr_id: r.pr_id,
          status: r.status,
          stage: r.stage,
          stage_started_at: r.stage_started_at,
          triggered_at: r.triggered_at,
          job_state: j.state
        }
    )
    |> Enum.map(&Map.put(&1, :liveness, liveness(&1.job_state)))
  end

  # nil = the job row was pruned or was never recorded; a completed job over an
  # unfinished review is a zombie. Neither is running.
  defp liveness(state) when state in @live_states, do: :running
  defp liveness(_state), do: :stalled

  @doc """
  How many review jobs are waiting to start.

  `create_review` runs *inside* `perform`, so a burst of labelled PRs has no
  review rows at all while it sits in the queue. Counting jobs is the only way
  those runs are visible.
  """
  def queued do
    Repo.aggregate(
      from(j in Oban.Job, where: j.queue == "reviews" and j.state in @live_states),
      :count
    )
  end

  @doc "Finished runs, newest first. Full structs — the expand renders metadata."
  def recent(opts \\ []) do
    Repo.all(
      from r in Review,
        where: r.status in ["complete", "failed"],
        order_by: [desc: r.triggered_at],
        limit: ^Keyword.get(opts, :limit, @recent_limit)
    )
  end

  @doc """
  Totals over the window.

  `:cost` is nil when no run in the window had rates configured — tokens are
  the primary number, cost is the one that can be missing.
  """
  def totals(opts \\ []) do
    from(r in Review, where: r.triggered_at >= ^since(opts))
    |> select([r], %{
      runs: count(r.id),
      cost: sum(r.cost_usd),
      input: coalesce(sum(r.input_tokens), 0),
      output: coalesce(sum(r.output_tokens), 0),
      failed: filter(count(r.id), r.status == "failed")
    })
    |> Repo.one()
  end

  @doc "Spend per repo over the window, most expensive first"
  def by_repo(opts \\ []) do
    from(r in Review, where: r.triggered_at >= ^since(opts))
    |> group_by([r], r.repo)
    |> order_by([r], desc: coalesce(sum(r.cost_usd), 0.0), desc: count(r.id))
    |> select([r], %{
      repo: r.repo,
      runs: count(r.id),
      cost: sum(r.cost_usd),
      input: coalesce(sum(r.input_tokens), 0),
      output: coalesce(sum(r.output_tokens), 0)
    })
    |> Repo.all()
  end

  @doc """
  One entry per day in the window, oldest first, including days with no runs.

  Gap-filling is the point: a sparkline that silently skips a quiet day draws
  a trend that never happened.
  """
  def daily(opts \\ []) do
    since = since(opts)

    counted =
      from(r in Review,
        where: r.triggered_at >= ^since,
        group_by: fragment("date_trunc('day', ?)::date", r.triggered_at),
        select: {
          fragment("date_trunc('day', ?)::date", r.triggered_at),
          %{cost: sum(r.cost_usd), runs: count(r.id)}
        }
      )
      |> Repo.all()
      |> Map.new()

    Date.range(DateTime.to_date(since), Date.utc_today())
    |> Enum.map(fn day ->
      %{cost: cost, runs: runs} = Map.get(counted, day, %{cost: nil, runs: 0})
      %{day: day, cost: cost, runs: runs}
    end)
  end

  @doc """
  Compression ratio per finished run, oldest first, as a percentage saved.

  Runs whose metadata has no compression block (failures, older rows) are
  dropped rather than plotted as zero.
  """
  def compression_trend(opts \\ []) do
    opts
    |> recent()
    |> Enum.reverse()
    |> Enum.flat_map(fn review ->
      case get_in(review.author_findings || %{}, ["metadata", "compression", "ratio"]) do
        ratio when is_number(ratio) -> [(1.0 - ratio) * 100]
        _ -> []
      end
    end)
  end

  @doc """
  M1 — compression over the window

  Only runs whose metadata carries a compression block are counted. A failed
  run never reached the stage, and averaging it in as zero would report a
  compression regression that never happened.

  `:runs` is 0 when nothing in the window compressed, in which case every
  other value is nil.
  """
  def compression(opts \\ []) do
    from(r in Review,
      where: r.triggered_at >= ^since(opts),
      where: not is_nil(fragment("? #> '{metadata,compression}'", r.author_findings)),
      select: %{
        runs: count(r.id),
        avg_saved:
          avg(
            fragment(
              "(1 - (? #>> '{metadata,compression,ratio}')::float) * 100",
              r.author_findings
            )
          ),
        original:
          sum(
            fragment("(? #>> '{metadata,compression,original_tokens}')::int", r.author_findings)
          ),
        compressed:
          sum(
            fragment("(? #>> '{metadata,compression,compressed_tokens}')::int", r.author_findings)
          ),
        dropped:
          sum(
            fragment(
              "(? #>> '{metadata,compression,truncated_sections}')::int",
              r.author_findings
            )
          )
      }
    )
    |> Repo.one()
  end

  @doc """
  M3 — tool agreement over the window

  `:rate` is nil until Gitleaks (G1-G3) actually runs. With no tool findings
  the rate is structurally 0%, and 0% reads as a bad score rather than as a
  missing measurement.
  """
  def agreement(opts \\ []) do
    row =
      from(r in Review,
        where: r.triggered_at >= ^since(opts),
        select: %{
          rate:
            avg(fragment("(? #>> '{metadata,tool_agreement_rate}')::float", r.author_findings)),
          tool_findings:
            sum(fragment("(? #>> '{metadata,gitleaks_findings_count}')::int", r.author_findings))
        }
      )
      |> Repo.one()

    tool_findings = row.tool_findings || 0

    %{rate: if(tool_findings > 0, do: row.rate), tool_findings: tool_findings}
  end

  @doc """
  M3 — how many findings landed in each confidence tier, over the window

  Reads the `findings` rows rather than the JSON blob: this is the aggregate
  the tiers exist for.
  """
  def confidence_counts(opts \\ []) do
    from(f in Finding,
      where: f.inserted_at >= ^since(opts),
      group_by: f.confidence,
      select: {f.confidence, count(f.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  M2 — secrets Gitleaks reported over the window, by category

  Empty until G1-G3 land, and the dashboard hides the section when it is:
  "0 secrets" from a pipeline that never looked for any is a claim, not a
  measurement.
  """
  def secrets_by_type(opts \\ []) do
    from(f in Finding,
      where: f.inserted_at >= ^since(opts) and f.source in ["gitleaks", "both"],
      group_by: f.category,
      order_by: [desc: count(f.id)],
      select: %{
        category: f.category,
        count: count(f.id),
        agreed: filter(count(f.id), f.source == "both")
      }
    )
    |> Repo.all()
  end

  @doc """
  M4 — per-agent findings, latency and failures over the window

  Folded in Elixir from the `per_agent` metadata the Spawner already computes,
  since the agent names are jsonb keys rather than rows. A few dozen runs of
  five small maps each.
  """
  def agent_stats(opts \\ []) do
    from(r in Review,
      where: r.triggered_at >= ^since(opts),
      select: fragment("? #> '{metadata,per_agent}'", r.author_findings)
    )
    |> Repo.all()
    |> Enum.reject(&(!is_map(&1)))
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {agent, rows} ->
      %{
        agent: agent,
        runs: length(rows),
        findings: sum_of(rows, "findings"),
        errors: Enum.count(rows, & &1["error"]),
        avg_ms: div(sum_of(rows, "ms"), length(rows)),
        input: sum_of(rows, ["usage", "input_tokens"]),
        output: sum_of(rows, ["usage", "output_tokens"])
      }
    end)
    |> Enum.sort_by(& &1.agent)
  end

  defp sum_of(rows, path) do
    path = List.wrap(path)

    Enum.reduce(rows, 0, fn row, total -> total + (get_in(row, path) || 0) end)
  end

  @doc """
  M4 — review latency over the window, in seconds

  Averages finished runs only: an in-flight run has no duration yet, and a
  snoozed one spent most of its wall-clock waiting on a rate limit.
  """
  def latency(opts \\ []) do
    from(r in Review,
      where: r.triggered_at >= ^since(opts) and not is_nil(r.completed_at),
      select: %{
        runs: count(r.id),
        avg: avg(fragment("extract(epoch from (? - ?))::float", r.completed_at, r.triggered_at)),
        max: max(fragment("extract(epoch from (? - ?))::float", r.completed_at, r.triggered_at))
      }
    )
    |> Repo.one()
  end

  @doc """
  `points` for an SVG `<polyline>`, scaled to fit `width` x `height`.

  Scales from zero, not from the minimum: a flat series near a high value
  should read as flat and high, not as noise filling the box.
  """
  def sparkline(values, width \\ 240, height \\ 40)
  def sparkline([], _width, _height), do: ""
  def sparkline([value], width, height), do: sparkline([value, value], width, height)

  def sparkline(values, width, height) do
    top = values |> Enum.max() |> max(0)
    top = if top == 0, do: 1.0, else: top * 1.0
    steps = length(values) - 1

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} ->
      x = index / steps * width
      y = height - max(value, 0) / top * height

      "#{Float.round(x * 1.0, 1)},#{Float.round(y * 1.0, 1)}"
    end)
  end

  @doc "Start of the window, as a UTC datetime"
  def since(opts \\ []) do
    DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :days, @window_days), :day)
  end

  @doc "The default window, in days"
  def window_days, do: @window_days
end
