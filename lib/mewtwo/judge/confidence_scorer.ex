defmodule Mewtwo.Judge.ConfidenceScorer do
  @moduledoc """
  J2 — assign confidence from corroboration, then rank

  Runs on deduplicated findings, so `sources` already records every agent and
  tool that reported each one. Confidence follows tool agreement:

    * `:high`   — a tool and an agent independently flagged the same issue
    * `:medium` — reported by agents only, or by the tool only
    * `:low`    — the reporting agent was itself unsure and nothing corroborates it

  An agent's self-reported confidence is only trusted downwards. A single agent
  claiming `:high` is still one unverified opinion, so it scores `:medium`;
  agreement between an agent and Gitleaks is what earns `:high`.
  """

  require Logger

  alias Mewtwo.Findings.AgentFinding

  @tool_sources ["gitleaks"]

  # Lower sorts first.
  @severity_rank %{high: 0, medium: 1, low: 2}
  @confidence_rank %{high: 0, medium: 1, low: 2}
  @worst_rank 3

  @doc """
  Attach confidence to each finding and return them ranked

  Ranking is severity first, then confidence, so a high/high finding leads.
  """
  def score(findings) do
    scored = Enum.map(findings, &score_finding/1)

    log_summary(scored)

    rank(scored)
  end

  @doc """
  Order findings by severity, then confidence

  Ties break on file then line, so the output is stable across runs.
  """
  def rank(findings) do
    Enum.sort_by(findings, fn finding ->
      {
        Map.get(@severity_rank, finding.severity, @worst_rank),
        Map.get(@confidence_rank, finding.confidence, @worst_rank),
        finding.file,
        finding.line
      }
    end)
  end

  @doc """
  Whether a source name refers to a static-analysis tool rather than an agent
  """
  def tool_source?(source), do: source in @tool_sources

  @doc """
  Whether a tool and an agent both reported this finding
  """
  def tool_agreement?(%AgentFinding{sources: sources}) do
    Enum.any?(sources, &tool_source?/1) and Enum.any?(sources, &(not tool_source?(&1)))
  end

  defp score_finding(%AgentFinding{} = finding) do
    %{finding | confidence: confidence_for(finding)}
  end

  defp confidence_for(%AgentFinding{} = finding) do
    cond do
      tool_agreement?(finding) -> :high
      uncertain?(finding) -> :low
      true -> :medium
    end
  end

  # A lone agent that flagged its own finding as low confidence stays low —
  # corroboration is what lifts a finding out of the uncertain bucket.
  defp uncertain?(%AgentFinding{confidence: :low, sources: sources}), do: length(sources) <= 1
  defp uncertain?(%AgentFinding{}), do: false


  defp log_summary(scored) do
    breakdown =
      scored
      |> Enum.frequencies_by(& &1.confidence)
      |> Enum.map_join(" ", fn {confidence, count} -> "#{confidence}=#{count}" end)

    agreed = Enum.count(scored, &tool_agreement?/1)

    Logger.info(
      "[judge] scored #{length(scored)} findings: #{breakdown} " <>
        "(#{agreed} with agent/tool agreement)"
    )
  end
end
