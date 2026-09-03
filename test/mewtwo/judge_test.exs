defmodule Mewtwo.JudgeTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Judge

  defp finding(opts) do
    {:ok, f} =
      AgentFinding.new(
        Keyword.get(opts, :file, "lib/a.ex"),
        Keyword.get(opts, :line, 1),
        Keyword.get(opts, :severity, :medium),
        Keyword.get(opts, :confidence, :medium),
        Keyword.get(opts, :category, "bugs"),
        Keyword.get(opts, :message, "fix it"),
        "because",
        agent_name: Keyword.get(opts, :agent_name, "bugs")
      )

    f
  end

  defp gitleaks(opts) do
    %{
      file: Keyword.get(opts, :file, "lib/a.ex"),
      line: Keyword.get(opts, :line, 1),
      type: Keyword.get(opts, :type, "api_key"),
      severity: Keyword.get(opts, :severity, :high)
    }
  end

  describe "acceptance: end to end" do
    test "turns agent and gitleaks findings into author and reviewer groups" do
      agent_findings = [
        # Corroborated by gitleaks below -> high confidence, actionable.
        finding(file: "lib/secrets.ex", line: 10, category: "security", severity: :high,
                agent_name: "security", message: "remove hardcoded key"),
        # Two agents agree -> medium, actionable.
        finding(file: "lib/pay.ex", line: 20, severity: :medium, agent_name: "bugs"),
        finding(file: "lib/pay.ex", line: 20, severity: :medium, agent_name: "perf"),
        # Lone unsure agent -> low, reviewer context.
        finding(file: "lib/style.ex", line: 30, severity: :high, confidence: :low,
                agent_name: "readability"),
        # Low severity -> reviewer context.
        finding(file: "lib/nit.ex", line: 40, severity: :low, agent_name: "readability")
      ]

      gitleaks_findings = [gitleaks(file: "lib/secrets.ex", line: 10)]

      {author, reviewer, metadata} = Judge.judge(agent_findings, gitleaks_findings)

      assert Enum.map(author, & &1.file) == ["lib/secrets.ex", "lib/pay.ex"]
      assert Enum.map(reviewer, & &1.file) == ["lib/style.ex", "lib/nit.ex"]

      [top | _] = author
      assert top.confidence == :high
      assert Enum.sort(top.sources) == ["gitleaks", "security"]

      assert metadata.gitleaks_findings_count == 1
      # 5 agent + 1 gitleaks = 6 in; the pay.ex pair and the secrets pair each
      # collapse, leaving 4.
      assert metadata.dedup_count == 2
      assert metadata.total_agents == 4
      assert metadata.tool_agreement_rate == 0.25
    end
  end

  describe "metadata" do
    test "counts distinct contributing agents" do
      findings = [
        finding(agent_name: "bugs", line: 1),
        finding(agent_name: "perf", line: 2),
        finding(agent_name: "bugs", line: 3)
      ]

      assert {_, _, %{total_agents: 2}} = Judge.judge(findings)
    end

    test "prefers an explicit total_agents over what the findings imply" do
      # Agents that ran and found nothing are invisible in the findings.
      findings = [finding(agent_name: "bugs")]

      assert {_, _, %{total_agents: 5}} = Judge.judge(findings, [], total_agents: 5)
    end

    test "does not count gitleaks as an agent" do
      assert {_, _, %{total_agents: 0}} = Judge.judge([], [gitleaks(line: 1)])
    end

    test "reports dedup_count as the number collapsed" do
      findings = for n <- 1..4, do: finding(agent_name: "a#{n}")

      assert {_, _, %{dedup_count: 3}} = Judge.judge(findings)
    end

    test "reports a zero dedup_count when nothing is duplicated" do
      findings = [finding(line: 1), finding(line: 2)]

      assert {_, _, %{dedup_count: 0}} = Judge.judge(findings)
    end

    test "computes tool_agreement_rate over surviving findings" do
      agreed = finding(file: "s.ex", line: 1, category: "security", agent_name: "security")
      alone = finding(file: "b.ex", line: 2, agent_name: "bugs")

      {_, _, metadata} = Judge.judge([agreed, alone], [gitleaks(file: "s.ex", line: 1)])

      # 2 surviving findings, 1 with agreement.
      assert metadata.tool_agreement_rate == 0.5
    end

    test "reports a zero agreement rate with no findings" do
      assert {[], [], metadata} = Judge.judge([], [])
      assert metadata.tool_agreement_rate == 0.0
      assert metadata.dedup_count == 0
      assert metadata.total_agents == 0
    end
  end

  describe "stage integration" do
    test "a gitleaks-only secret reaches reviewers as a medium finding" do
      # Nothing corroborates it, so it is medium and high severity -> actionable.
      {author, reviewer, _} = Judge.judge([], [gitleaks(line: 5, type: "aws_key")])

      assert reviewer == []
      assert [only] = author
      assert only.confidence == :medium
      assert only.severity == :high
      assert only.category == "security"
      assert only.sources == ["gitleaks"]
    end

    test "returns author findings ranked most severe first" do
      findings = [
        finding(file: "low.ex", severity: :low, line: 1),
        finding(file: "med.ex", severity: :medium, line: 2),
        finding(file: "high.ex", severity: :high, line: 3)
      ]

      {author, reviewer, _} = Judge.judge(findings)

      assert Enum.map(author, & &1.file) == ["high.ex", "med.ex"]
      assert Enum.map(reviewer, & &1.file) == ["low.ex"]
    end
  end
end
