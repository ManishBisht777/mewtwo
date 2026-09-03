defmodule Mewtwo.Judge.DeduplicatorTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Judge.Deduplicator

  defp finding(opts) do
    {:ok, f} =
      AgentFinding.new(
        Keyword.get(opts, :file, "lib/a.ex"),
        Keyword.get(opts, :line, 1),
        Keyword.get(opts, :severity, :medium),
        Keyword.get(opts, :confidence, :medium),
        Keyword.get(opts, :category, "bugs"),
        Keyword.get(opts, :message, "fix it"),
        Keyword.get(opts, :reasoning, "because"),
        agent_name: Keyword.get(opts, :agent_name, "bugs"),
        sources: Keyword.get(opts, :sources, [])
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

  describe "acceptance: 20 findings with 5 duplicates" do
    test "collapses to 15 and marks the duplicates" do
      # 15 distinct findings, then 5 that repeat the first 5 from another agent.
      distinct = for n <- 1..15, do: finding(file: "lib/f#{n}.ex", line: n, agent_name: "bugs")
      dupes = for n <- 1..5, do: finding(file: "lib/f#{n}.ex", line: n, agent_name: "perf")

      result = Deduplicator.deduplicate(distinct ++ dupes)

      assert length(result) == 15

      {confirmed, single} = Enum.split_with(result, &(AgentFinding.source_count(&1) > 1))
      assert length(confirmed) == 5
      assert length(single) == 10

      assert Enum.all?(confirmed, &(Enum.sort(&1.sources) == ["bugs", "perf"]))
      assert Enum.all?(single, &(&1.sources == ["bugs"]))
    end
  end

  describe "grouping" do
    test "merges findings sharing file, line and category" do
      a = finding(agent_name: "bugs")
      b = finding(agent_name: "perf")

      assert [merged] = Deduplicator.deduplicate([a, b])
      assert Enum.sort(merged.sources) == ["bugs", "perf"]
    end

    test "keeps findings on the same line in different categories separate" do
      a = finding(category: "bugs", agent_name: "bugs")
      b = finding(category: "security", agent_name: "security")

      assert length(Deduplicator.deduplicate([a, b])) == 2
    end

    test "keeps findings in the same file on different lines separate" do
      a = finding(line: 10)
      b = finding(line: 11)

      assert length(Deduplicator.deduplicate([a, b])) == 2
    end

    test "treats category as case-insensitive" do
      a = finding(category: "Bugs", agent_name: "bugs")
      b = finding(category: "bugs", agent_name: "perf")

      assert [merged] = Deduplicator.deduplicate([a, b])
      assert Enum.sort(merged.sources) == ["bugs", "perf"]
    end

    test "treats ./path and path as the same file" do
      a = finding(file: "./lib/a.ex", agent_name: "bugs")
      b = finding(file: "lib/a.ex", agent_name: "perf")

      assert [merged] = Deduplicator.deduplicate([a, b])
      assert Enum.sort(merged.sources) == ["bugs", "perf"]
    end

    test "collapses two findings from the same agent to a single source" do
      a = finding(agent_name: "bugs", message: "first")
      b = finding(agent_name: "bugs", message: "second")

      assert [merged] = Deduplicator.deduplicate([a, b])
      assert merged.sources == ["bugs"]
      assert AgentFinding.source_count(merged) == 1
    end

    test "preserves first-appearance order of groups" do
      findings = [
        finding(file: "c.ex", line: 3),
        finding(file: "a.ex", line: 1),
        finding(file: "b.ex", line: 2)
      ]

      assert ["c.ex", "a.ex", "b.ex"] = Enum.map(Deduplicator.deduplicate(findings), & &1.file)
    end
  end

  describe "representative selection" do
    test "keeps the most severe finding in a group" do
      low = finding(severity: :low, agent_name: "bugs", message: "low one")
      high = finding(severity: :high, agent_name: "perf", message: "high one")

      assert [rep] = Deduplicator.deduplicate([low, high])
      assert rep.severity == :high
      assert rep.message == "high one"
    end

    test "breaks a severity tie on confidence" do
      unsure = finding(severity: :high, confidence: :low, agent_name: "bugs", message: "unsure")
      sure = finding(severity: :high, confidence: :high, agent_name: "perf", message: "sure")

      assert [rep] = Deduplicator.deduplicate([unsure, sure])
      assert rep.message == "sure"
    end

    test "breaks a severity and confidence tie on the fuller reasoning" do
      terse = finding(agent_name: "bugs", message: "terse", reasoning: "no")
      detailed = finding(agent_name: "perf", message: "detailed", reasoning: "a much longer why")

      assert [rep] = Deduplicator.deduplicate([terse, detailed])
      assert rep.message == "detailed"
    end

    test "the representative still carries every source in its group" do
      low = finding(severity: :low, agent_name: "bugs")
      high = finding(severity: :high, agent_name: "perf")

      assert [rep] = Deduplicator.deduplicate([low, high])
      assert Enum.sort(rep.sources) == ["bugs", "perf"]
    end
  end

  describe "gitleaks findings" do
    test "merges a gitleaks hit with a matching security finding" do
      agent = finding(category: "security", line: 7, agent_name: "security")

      assert [merged] = Deduplicator.deduplicate([agent], [gitleaks(line: 7)])
      assert Enum.sort(merged.sources) == ["gitleaks", "security"]
      assert AgentFinding.source_count(merged) == 2
    end

    test "keeps a gitleaks hit that no agent reported" do
      assert [only] = Deduplicator.deduplicate([], [gitleaks(line: 9, type: "aws_key")])

      assert only.sources == ["gitleaks"]
      assert only.category == "security"
      assert only.line == 9
      assert only.severity == :high
      assert only.message =~ "aws_key"
      assert only.reasoning =~ "Gitleaks"
    end

    test "does not merge a gitleaks hit into a non-security finding on the same line" do
      agent = finding(category: "bugs", line: 7, agent_name: "bugs")

      result = Deduplicator.deduplicate([agent], [gitleaks(line: 7)])

      assert length(result) == 2
    end

    test "accepts string keys and a stringified line" do
      raw = %{"file" => "lib/a.ex", "line" => "12", "type" => "token", "severity" => "high"}

      assert [only] = Deduplicator.deduplicate([], [raw])
      assert only.line == 12
      assert only.severity == :high
    end

    test "defaults severity to :high for an unrecognised value" do
      assert [only] = Deduplicator.deduplicate([], [gitleaks(severity: "catastrophic")])
      assert only.severity == :high
    end

    test "drops gitleaks findings that cannot be located" do
      unusable = [
        %{line: 3, type: "key"},
        %{file: "", line: 3},
        %{file: "lib/a.ex"},
        %{file: "lib/a.ex", line: 0},
        %{file: "lib/a.ex", line: "not a number"}
      ]

      assert Deduplicator.deduplicate([], unusable) == []
    end
  end

  describe "edge cases" do
    test "returns [] for no findings at all" do
      assert Deduplicator.deduplicate([]) == []
      assert Deduplicator.deduplicate([], []) == []
    end

    test "gitleaks findings alone are enough" do
      assert length(Deduplicator.deduplicate([], [gitleaks(line: 1), gitleaks(line: 2)])) == 2
    end

    test "labels a finding with no agent_name as an unknown source" do
      assert [only] = Deduplicator.deduplicate([finding(agent_name: nil)])
      assert only.sources == ["unknown"]
    end

    test "is idempotent — re-running preserves sources rather than losing them" do
      findings = [finding(agent_name: "bugs"), finding(agent_name: "perf")]

      once = Deduplicator.deduplicate(findings)
      twice = Deduplicator.deduplicate(once)

      assert twice == once
      assert [%{sources: sources}] = twice
      assert Enum.sort(sources) == ["bugs", "perf"]
    end
  end
end
