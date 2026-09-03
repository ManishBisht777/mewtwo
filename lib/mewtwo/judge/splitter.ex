defmodule Mewtwo.Judge.Splitter do
  @moduledoc """
  J3 — split findings into what the author must act on and what a reviewer may want

  Author findings are the actionable set: high or medium severity that we are
  not unsure about. Everything else — low severity, or anything still scored
  `:low` confidence — goes to reviewers as context.

  A high-severity finding with `:low` confidence lands in the reviewer group on
  purpose. Nothing erodes trust in a review bot faster than confidently telling
  an author to fix something that isn't broken, so unverified findings are
  offered to a human rather than demanded of the author.
  """

  require Logger

  alias Mewtwo.Findings.AgentFinding

  @actionable_severities [:high, :medium]

  @doc """
  Partition ranked findings into `{author_findings, reviewer_findings}`

  Input order is preserved within each group, so a ranked input yields two
  ranked outputs.
  """
  def split(findings) do
    {author, reviewer} = Enum.split_with(findings, &actionable?/1)

    Logger.info(
      "[judge] split #{length(findings)} findings: " <>
        "#{length(author)} for the author, #{length(reviewer)} for reviewers"
    )

    {author, reviewer}
  end

  @doc """
  Whether a finding is actionable enough to put in front of the author
  """
  def actionable?(%AgentFinding{severity: severity, confidence: confidence}) do
    severity in @actionable_severities and confidence != :low
  end
end
