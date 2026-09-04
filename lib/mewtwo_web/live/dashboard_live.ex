defmodule MewtwoWeb.DashboardLive do
  @moduledoc """
  One page: what is in flight, which stage each run is on, and what it cost.

  Refresh is PubSub-driven — the worker broadcasts each stage boundary and the
  Spawner broadcasts per agent, because per-agent progress exists nowhere but
  the broadcast until the run finishes. A 1s local tick advances the elapsed
  clocks with no DB hit; a slower tick re-reads the DB, since a queued job and
  a node that died mid-run both produce no broadcast at all.
  """

  use MewtwoWeb, :live_view

  alias Mewtwo.{Cost, Dashboard}
  alias Mewtwo.Findings.Finding
  alias Phoenix.PubSub

  # Order the checklist renders in. A run's real agent list is only known once
  # it finishes, so in-flight rows show the default five.
  @agents ~w(bugs perf security architecture readability)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(Mewtwo.PubSub, "reviews")
      :timer.send_interval(1_000, self(), :tick)
      :timer.send_interval(10_000, self(), :reload)
    end

    {:ok,
     socket
     |> assign(page_title: "Dashboard", expanded: MapSet.new(), agents: %{}, findings: %{})
     |> load()}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  def handle_info(:reload, socket), do: {:noreply, load(socket)}

  def handle_info({:stage, _review_id, _stage}, socket), do: {:noreply, load(socket)}

  # Per-agent progress is not persisted until the run completes, so this is
  # tracked in assigns only.
  def handle_info({:agent, review_id, agent, status}, socket) do
    agents =
      Map.update(
        socket.assigns.agents,
        review_id,
        %{agent => status},
        &Map.put(&1, agent, status)
      )

    {:noreply, assign(socket, agents: agents)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    if MapSet.member?(expanded, id) do
      {:noreply, assign(socket, expanded: MapSet.delete(expanded, id))}
    else
      # Loaded on expand, not with the list: 25 runs x N findings is a lot of
      # rows to carry in assigns for the one row someone opened.
      {:noreply,
       assign(socket,
         expanded: MapSet.put(expanded, id),
         findings: Map.put_new_lazy(socket.assigns.findings, id, fn -> Finding.for_review(id) end)
       )}
    end
  end

  defp load(socket) do
    in_flight = Dashboard.in_flight()
    daily = Dashboard.daily()

    assign(socket,
      now: DateTime.utc_now(),
      totals: Dashboard.totals(),
      by_repo: Dashboard.by_repo(),
      queued: Dashboard.queued(),
      running: Enum.filter(in_flight, &(&1.liveness == :running)),
      stalled: Enum.filter(in_flight, &(&1.liveness == :stalled)),
      recent: Dashboard.recent(),
      cost_spark: Dashboard.sparkline(Enum.map(daily, &(&1.cost || 0.0))),
      runs_spark: Dashboard.sparkline(Enum.map(daily, & &1.runs)),
      compression_spark: Dashboard.sparkline(Dashboard.compression_trend()),
      compression: Dashboard.compression(),
      latency: Dashboard.latency(),
      confidence: Dashboard.confidence_counts(),
      agreement: Dashboard.agreement(),
      secrets: Dashboard.secrets_by_type(),
      agent_stats: Dashboard.agent_stats()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6 space-y-8 font-mono text-sm">
      <h1 class="text-lg font-semibold">
        mewtwo · last {Dashboard.window_days()} days
      </h1>

      <section class="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <.tile label="runs" value={@totals.runs} spark={@runs_spark} />
        <.tile label="cost" value={usd(@totals.cost)} spark={@cost_spark} />
        <.tile label="tokens" value={"#{tokens(@totals.input)} in / #{tokens(@totals.output)} out"} />
        <.tile label="failed" value={@totals.failed} />
      </section>

      <section>
        <.heading>queued <span class="opacity-60">({@queued})</span></.heading>
        <p :if={@queued == 0} class="opacity-60">nothing waiting</p>
        <p :if={@queued > 0} class="opacity-60">
          {@queued} job(s) in the :reviews queue, not started yet
        </p>
      </section>

      <section>
        <.heading>running <span class="opacity-60">({length(@running)})</span></.heading>
        <p :if={@running == []} class="opacity-60">idle</p>

        <ul class="divide-y divide-base-300">
          <li :for={run <- @running} class="py-2 flex flex-wrap items-center gap-x-4 gap-y-1">
            <span class="w-48 truncate">{run.repo}#{run.pr_id}</span>
            <span class="w-20 badge badge-sm badge-primary">{run.stage || "—"}</span>
            <span class="w-14 tabular-nums opacity-70">{secs(@now, run.stage_started_at)}</span>
            <.checklist :if={run.stage == "agents"} states={Map.get(@agents, run.id, %{})} />
          </li>
        </ul>
      </section>

      <section :if={@stalled != []}>
        <.heading>stalled <span class="opacity-60">({length(@stalled)})</span></.heading>

        <ul class="divide-y divide-base-300">
          <li :for={run <- @stalled} class="py-2 flex flex-wrap items-center gap-x-4 gap-y-1">
            <span class="w-48 truncate">{run.repo}#{run.pr_id}</span>
            <span class="w-20 badge badge-sm badge-warning">{run.stage || "—"}</span>
            <span class="w-14 tabular-nums opacity-70">{secs(@now, run.triggered_at)}</span>
            <span class="opacity-70">job {run.job_state || "gone"}</span>
          </li>
        </ul>
      </section>

      <section :if={@by_repo != []}>
        <.heading>cost by repo</.heading>

        <ul class="divide-y divide-base-300">
          <li :for={row <- @by_repo} class="py-2 flex flex-wrap items-center gap-x-4">
            <span class="w-48 truncate">{row.repo}</span>
            <span class="w-16 tabular-nums opacity-70">{row.runs} runs</span>
            <span class="w-20 tabular-nums">{usd(row.cost)}</span>
            <span class="opacity-70 tabular-nums">
              {tokens(row.input)} in / {tokens(row.output)} out
            </span>
          </li>
        </ul>
      </section>

      <section>
        <.heading>pipeline</.heading>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-8">
          <p :if={@compression.runs > 0} class="opacity-70">
            compression {pct(@compression.avg_saved)} saved over {@compression.runs} run(s) · {tokens(
              @compression.original
            )} → {tokens(@compression.compressed)} tokens · {@compression.dropped || 0} file(s) dropped
          </p>

          <p :if={@latency.runs > 0} class="opacity-70">
            latency {secs_of(@latency.avg)} avg, {secs_of(@latency.max)} worst
            over {@latency.runs} finished run(s)
          </p>

          <p :if={@confidence != %{}} class="opacity-70">
            confidence
            <span :for={tier <- ~w(high medium low)} :if={@confidence[tier]}>
              {tier} {@confidence[tier]}
            </span>
          </p>

          <%!-- Omitted while gitleaks has produced nothing: the rate is
                structurally 0% until G1-G3 land, and a fake zero reads as a
                bad score rather than as a missing measurement. --%>
          <p :if={@agreement.rate} class="opacity-70">
            tool agreement {pct(@agreement.rate * 100)} of findings verified by both · {@agreement.tool_findings} tool finding(s)
          </p>
        </div>
      </section>

      <section :if={@secrets != []}>
        <.heading>secrets</.heading>

        <ul class="divide-y divide-base-300">
          <li :for={row <- @secrets} class="py-1 flex items-center gap-x-4">
            <span class="w-32 truncate">{row.category}</span>
            <span class="w-16 tabular-nums">{row.count}</span>
            <span class="opacity-70">{row.agreed} also flagged by an agent</span>
          </li>
        </ul>
      </section>

      <section :if={@agent_stats != []}>
        <.heading>agents</.heading>

        <ul class="divide-y divide-base-300">
          <li :for={row <- @agent_stats} class="py-1 flex flex-wrap items-center gap-x-4">
            <span class="w-28">{row.agent}</span>
            <span class="w-16 tabular-nums opacity-70">{row.runs} runs</span>
            <span class="w-14 tabular-nums opacity-70">{ms(row.avg_ms)}</span>
            <span class="w-20 tabular-nums opacity-70">{tokens(row.input)}/{tokens(row.output)}</span>
            <span class="w-24 tabular-nums">{row.findings} findings</span>
            <span :if={row.errors > 0} class="text-error">{row.errors} failed</span>
          </li>
        </ul>
      </section>

      <section :if={@compression_spark != ""}>
        <.heading>compression saved (% per run)</.heading>
        <svg viewBox="0 0 240 40" class="w-full h-10 text-primary" preserveAspectRatio="none">
          <polyline points={@compression_spark} fill="none" stroke="currentColor" stroke-width="1.5" />
        </svg>
      </section>

      <section>
        <.heading>recent</.heading>
        <p :if={@recent == []} class="opacity-60">no finished runs yet</p>

        <ul class="divide-y divide-base-300">
          <li :for={review <- @recent} class="py-2">
            <button
              type="button"
              phx-click="toggle"
              phx-value-id={review.id}
              class="w-full text-left flex flex-wrap items-center gap-x-4 gap-y-1 hover:opacity-70"
            >
              <span class="w-4 opacity-60">{if expanded?(@expanded, review), do: "▾", else: "▸"}</span>
              <span class="w-44 truncate">{review.repo}#{review.pr_id}</span>
              <span class={["w-20 badge badge-sm", status_class(review.status)]}>{review.status}</span>
              <span class="w-14 tabular-nums opacity-70">{duration(review)}</span>
              <span class="w-20 tabular-nums">{usd(review.cost_usd)}</span>
              <span class="opacity-70">{finding_count(review)} findings</span>
            </button>

            <.detail
              :if={expanded?(@expanded, review)}
              review={review}
              findings={Map.get(@findings, review.id, [])}
            />
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :spark, :string, default: nil

  defp tile(assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-3">
      <div class="text-xs uppercase opacity-60">{@label}</div>
      <div class="text-base tabular-nums">{@value}</div>
      <svg
        :if={@spark not in [nil, ""]}
        viewBox="0 0 240 40"
        class="w-full h-6 mt-1 text-primary"
        preserveAspectRatio="none"
      >
        <polyline points={@spark} fill="none" stroke="currentColor" stroke-width="2" />
      </svg>
    </div>
    """
  end

  slot :inner_block, required: true

  defp heading(assigns) do
    ~H"""
    <h2 class="text-xs uppercase tracking-wide opacity-60 mb-2">{render_slot(@inner_block)}</h2>
    """
  end

  attr :states, :map, required: true

  defp checklist(assigns) do
    assigns = assign(assigns, :agents, @agents)

    ~H"""
    <span class="flex items-center gap-2">
      <span class="tracking-widest" title={inspect(@states)}>
        <span :for={agent <- @agents} class={dot_class(Map.get(@states, agent))}>
          {if Map.get(@states, agent) in [:ok, :error], do: "●", else: "○"}
        </span>
      </span>
      <span class="opacity-70 tabular-nums">{done_count(@states)}/{length(@agents)}</span>
    </span>
    """
  end

  attr :review, :map, required: true
  attr :findings, :list, default: []

  defp detail(assigns) do
    assigns = assign(assigns, :meta, metadata(assigns.review))

    ~H"""
    <div class="mt-2 ml-8 space-y-1 text-xs">
      <p :if={@review.error} class="text-error break-all">{@review.error}</p>

      <div :for={{agent, row} <- per_agent(@meta)} class="flex flex-wrap gap-x-4">
        <span class="w-28">{agent}</span>
        <span class="w-14 tabular-nums opacity-70">{ms(row["ms"])}</span>
        <span class="w-28 tabular-nums opacity-70">
          {tokens(row["usage"]["input_tokens"])}/{tokens(row["usage"]["output_tokens"])}
        </span>
        <span class="w-20 tabular-nums">{usd(agent_cost(row))}</span>
        <span class="opacity-70">{row["findings"]} findings</span>
        <span :if={row["error"]} class="text-error break-all">{row["error"]}</span>
      </div>

      <p :if={@meta["compression"]} class="opacity-70">
        compress {tokens(@meta["compression"]["original_tokens"])} → {tokens(
          @meta["compression"]["compressed_tokens"]
        )} tokens
        ({saved(@meta["compression"]["ratio"])}), {@meta["compression"]["truncated_sections"]} files dropped
      </p>

      <p :if={@meta["context"]} class="opacity-70">
        context {@meta["context"]["fetched"]} fetched, {@meta["context"]["skipped"]} skipped, {tokens(
          @meta["context"]["tokens_used"]
        )} tokens
      </p>

      <p :if={is_nil(@meta["context"]) and @meta != %{}} class="opacity-70">
        context skipped — no repo checkout, agents saw the diff only
      </p>

      <p :if={@meta["dedup_count"]} class="opacity-70">
        judge {raw_findings(@review, @meta)} raw → {finding_count(@review)} author / {reviewer_count(
          @review
        )} reviewer, {@meta["dedup_count"]} deduped
      </p>

      <p :if={@meta["publish"]} class="opacity-70">
        publish {@meta["publish"]["status"]}{publish_detail(@meta["publish"])}
      </p>

      <div :for={finding <- @findings} class="flex flex-wrap gap-x-3">
        <span class={["w-16", severity_class(finding.severity)]}>{finding.severity}</span>
        <span class="w-16 opacity-60">{finding.confidence}</span>
        <span class="w-16 opacity-60">{finding.source}</span>
        <span class="truncate">{finding.file}:{finding.line} — {finding.message}</span>
      </div>
    </div>
    """
  end

  defp expanded?(expanded, review), do: MapSet.member?(expanded, review.id)

  defp metadata(review), do: get_in(review.author_findings || %{}, ["metadata"]) || %{}

  defp per_agent(meta) do
    meta
    |> Map.get("per_agent", %{})
    |> Enum.sort_by(fn {agent, _row} -> Enum.find_index(@agents, &(&1 == agent)) || 99 end)
  end

  defp agent_cost(row) do
    usage = %{
      input_tokens: row["usage"]["input_tokens"] || 0,
      output_tokens: row["usage"]["output_tokens"] || 0,
      calls: row["usage"]["calls"] || 0
    }

    case Cost.estimate(usage) do
      {:ok, cost} -> cost
      :no_rates -> nil
    end
  end

  defp finding_count(review), do: (review.author_findings || %{})["count"] || 0
  defp reviewer_count(review), do: (review.reviewer_findings || %{})["count"] || 0

  defp raw_findings(review, meta) do
    finding_count(review) + reviewer_count(review) + (meta["dedup_count"] || 0)
  end

  defp publish_detail(%{"review_id" => id, "inline_comments" => n}),
    do: " · review #{id} · #{n} inline"

  defp publish_detail(%{"reason" => reason}), do: " · #{reason}"
  defp publish_detail(_publish), do: ""

  defp done_count(states),
    do: Enum.count(states, fn {_agent, status} -> status in [:ok, :error] end)

  defp dot_class(:ok), do: "text-success"
  defp dot_class(:error), do: "text-error"
  defp dot_class(:running), do: "text-primary animate-pulse"
  defp dot_class(_status), do: "opacity-30"

  defp severity_class("high"), do: "text-error"
  defp severity_class("medium"), do: "text-warning"
  defp severity_class(_severity), do: "opacity-60"

  defp status_class("complete"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class(_status), do: "badge-ghost"

  # Tokens are the primary number, so a missing rate renders as "—" and never
  # as $0.00 — a free review would be a lie.
  defp usd(nil), do: "—"
  defp usd(amount), do: Cost.format_usd(amount * 1.0)

  defp tokens(nil), do: "0"
  defp tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp tokens(n), do: to_string(n)

  defp ms(nil), do: "—"
  defp ms(n), do: "#{Float.round(n / 1000, 1)}s"

  defp pct(nil), do: "—"
  defp pct(value), do: "#{round(value)}%"

  defp secs_of(nil), do: "—"
  defp secs_of(seconds), do: humanize(round(seconds))

  defp saved(nil), do: "—"
  defp saved(ratio), do: "#{round((1.0 - ratio) * 100)}%"

  defp secs(_now, nil), do: "—"

  defp secs(now, then) do
    now |> DateTime.diff(then) |> max(0) |> humanize()
  end

  defp duration(%{triggered_at: from, completed_at: to}) when not is_nil(to) do
    humanize(max(DateTime.diff(to, from), 0))
  end

  defp duration(_review), do: "—"

  defp humanize(seconds) when seconds < 60, do: "#{seconds}s"
  defp humanize(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp humanize(seconds), do: "#{div(seconds, 3600)}h"
end
