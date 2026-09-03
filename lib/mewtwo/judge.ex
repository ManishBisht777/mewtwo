defmodule Mewtwo.Judge do
  @moduledoc """
  J4 — turn raw agent and tool output into a review

  Runs deduplication (J1) → confidence scoring (J2) → splitting (J3) and
  reports metadata about what happened along the way.
  """

  require Logger

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Judge.{ConfidenceScorer, Deduplicator, Splitter}

  @doc """
  Judge agent and Gitleaks findings

  Returns `{author_findings, reviewer_findings, metadata}` where metadata is:

    * `:total_agents` — how many agents contributed findings
    * `:gitleaks_findings_count` — Gitleaks findings received
    * `:dedup_count` — how many findings were collapsed as duplicates
    * `:tool_agreement_rate` — fraction of surviving findings that an agent and
      a tool both reported, `0.0..1.0`

  Options:

    * `:total_agents` — the number of agents that actually ran. Pass it when
      known: it is otherwise inferred from the distinct agents present in the
      findings, which undercounts any agent that ran and found nothing.
  """
  def judge(agent_findings, gitleaks_findings \\ [], opts \\ []) do
    started = System.monotonic_time(:millisecond)
    input_count = length(agent_findings) + length(gitleaks_findings)

    Logger.info(
      "[judge] start: #{length(agent_findings)} agent findings, " <>
        "#{length(gitleaks_findings)} gitleaks findings"
    )

    deduplicated = Deduplicator.deduplicate(agent_findings, gitleaks_findings)
    scored = ConfidenceScorer.score(deduplicated)
    {author, reviewer} = Splitter.split(scored)

    metadata = %{
      total_agents: total_agents(agent_findings, opts),
      gitleaks_findings_count: length(gitleaks_findings),
      dedup_count: input_count - length(deduplicated),
      tool_agreement_rate: tool_agreement_rate(scored)
    }

    Logger.info(
      "[judge] done in #{System.monotonic_time(:millisecond) - started}ms: " <>
        "#{length(author)} author + #{length(reviewer)} reviewer findings, " <>
        "#{metadata.dedup_count} deduplicated, " <>
        "#{round(metadata.tool_agreement_rate * 100)}% tool agreement"
    )

    log_group("author", author)
    log_group("reviewer", reviewer)

    {author, reviewer, metadata}
  end

  defp log_group(_label, []), do: :ok

  defp log_group(label, findings) do
    Logger.info("[judge] #{label} findings:")

    Enum.each(findings, fn finding ->
      Logger.info(
        "[judge]   #{finding.severity}/#{finding.confidence} #{finding.file}:#{finding.line} " <>
          "[#{finding.category}] confirmed by #{Enum.join(finding.sources, "+")} — #{finding.message}"
      )
    end)
  end

  defp total_agents(agent_findings, opts) do
    case Keyword.get(opts, :total_agents) do
      nil ->
        agent_findings
        |> Enum.flat_map(&agents_of/1)
        |> Enum.uniq()
        |> length()

      given ->
        given
    end
  end

  # Findings may arrive pre-deduplicated, in which case the contributing
  # agents are in `sources` rather than `agent_name` — and `sources` can also
  # name tools, which must not be counted as agents.
  defp agents_of(%AgentFinding{sources: [_ | _] = sources}) do
    Enum.reject(sources, &ConfidenceScorer.tool_source?/1)
  end

  defp agents_of(%AgentFinding{agent_name: nil}), do: []
  defp agents_of(%AgentFinding{agent_name: name}), do: [name]

  defp tool_agreement_rate([]), do: 0.0

  defp tool_agreement_rate(findings) do
    agreed = Enum.count(findings, &ConfidenceScorer.tool_agreement?/1)

    Float.round(agreed / length(findings), 3)
  end
end
