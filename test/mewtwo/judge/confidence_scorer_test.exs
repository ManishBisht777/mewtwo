defmodule Mewtwo.Judge.ConfidenceScorerTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Judge.ConfidenceScorer

  defp finding(opts) do
    {:ok, f} =
      AgentFinding.new(
        Keyword.get(opts, :file, "lib/a.ex"),
        Keyword.get(opts, :line, 1),
        Keyword.get(opts, :severity, :medium),
        Keyword.get(opts, :confidence, :medium),
        Keyword.get(opts, :category, "bugs"),
        "fix it",
        "because",
        agent_name: Keyword.get(opts, :agent_name, "bugs"),
        sources: Keyword.get(opts, :sources, ["bugs"])
      )

    f
  end

  describe "acceptance: scoring rules" do
    test "an agent and Gitleaks flagging the same issue scores high" do
      f = finding(sources: ["security", "gitleaks"], confidence: :low)

      assert [%{confidence: :high}] = ConfidenceScorer.score([f])
    end

    test "an agent alone scores medium" do
      assert [%{confidence: :medium}] = ConfidenceScorer.score([finding(sources: ["bugs"])])
    end

    test "Gitleaks alone scores medium" do
      assert [%{confidence: :medium}] = ConfidenceScorer.score([finding(sources: ["gitleaks"])])
    end

    test "an unsure lone agent scores low" do
      f = finding(sources: ["bugs"], confidence: :low)

      assert [%{confidence: :low}] = ConfidenceScorer.score([f])
    end

    test "a single agent claiming high confidence is still only medium" do
      # One unverified opinion is not corroboration.
      f = finding(sources: ["bugs"], confidence: :high)

      assert [%{confidence: :medium}] = ConfidenceScorer.score([f])
    end

    test "agreement lifts an unsure finding out of the low bucket" do
      f = finding(sources: ["bugs", "perf"], confidence: :low)

      assert [%{confidence: :medium}] = ConfidenceScorer.score([f])
    end
  end

  describe "acceptance: ranking" do
    test "high severity with high confidence ranks first" do
      findings = [
        finding(severity: :low, sources: ["bugs"], file: "low.ex"),
        finding(severity: :high, sources: ["security", "gitleaks"], file: "top.ex"),
        finding(severity: :medium, sources: ["bugs"], file: "mid.ex")
      ]

      assert ["top.ex", "mid.ex", "low.ex"] =
               findings |> ConfidenceScorer.score() |> Enum.map(& &1.file)
    end

    test "severity outranks confidence" do
      high_sev_low_conf = finding(severity: :high, confidence: :low, sources: ["bugs"], file: "a.ex")
      low_sev_agreed = finding(severity: :low, sources: ["s", "gitleaks"], file: "b.ex")

      assert ["a.ex", "b.ex"] =
               [low_sev_agreed, high_sev_low_conf]
               |> ConfidenceScorer.score()
               |> Enum.map(& &1.file)
    end

    test "confidence breaks a severity tie" do
      agreed = finding(severity: :high, sources: ["s", "gitleaks"], file: "agreed.ex")
      alone = finding(severity: :high, sources: ["bugs"], file: "alone.ex")

      assert ["agreed.ex", "alone.ex"] =
               [alone, agreed] |> ConfidenceScorer.score() |> Enum.map(& &1.file)
    end

    test "ranking is stable, breaking ties on file then line" do
      findings = [
        finding(file: "b.ex", line: 1),
        finding(file: "a.ex", line: 9),
        finding(file: "a.ex", line: 2)
      ]

      assert [{"a.ex", 2}, {"a.ex", 9}, {"b.ex", 1}] =
               findings |> ConfidenceScorer.score() |> Enum.map(&{&1.file, &1.line})
    end
  end

  describe "tool_agreement?/1 and tool_source?/1" do
    test "requires both a tool and an agent" do
      assert ConfidenceScorer.tool_agreement?(finding(sources: ["security", "gitleaks"]))
      refute ConfidenceScorer.tool_agreement?(finding(sources: ["gitleaks"]))
      refute ConfidenceScorer.tool_agreement?(finding(sources: ["bugs", "perf"]))
      refute ConfidenceScorer.tool_agreement?(finding(sources: []))
    end

    test "identifies tool sources" do
      assert ConfidenceScorer.tool_source?("gitleaks")
      refute ConfidenceScorer.tool_source?("bugs")
    end
  end

  describe "edge cases" do
    test "returns [] for no findings" do
      assert ConfidenceScorer.score([]) == []
    end

    test "is idempotent" do
      findings = [
        finding(sources: ["s", "gitleaks"]),
        finding(sources: ["bugs"], confidence: :low, line: 2),
        finding(sources: ["bugs"], line: 3)
      ]

      once = ConfidenceScorer.score(findings)
      assert ConfidenceScorer.score(once) == once
    end
  end
end
