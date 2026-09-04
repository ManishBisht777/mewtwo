defmodule Mewtwo.Github.FindingGrouperTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Github.FindingGrouper

  defp finding(opts) do
    {:ok, f} =
      AgentFinding.new(
        Keyword.get(opts, :file, "lib/a.ex"),
        Keyword.get(opts, :line, 1),
        Keyword.get(opts, :severity, :medium),
        Keyword.get(opts, :confidence, :medium),
        Keyword.get(opts, :category, "architecture"),
        Keyword.get(opts, :message, "handles nil badly"),
        Keyword.get(opts, :reasoning, "because"),
        agent_name: Keyword.get(opts, :agent_name, "architecture")
      )

    f
  end

  # The findings that motivated this module: one habit, reported per file, in
  # slightly different words each time.
  defp cross_module_findings do
    [
      finding(
        file: "components/bookfolio/components/ProjectDescription.tsx",
        message: "Remove cross-module dependency from bookfolio to portfolio data layer"
      ),
      finding(
        file: "components/bookfolio/components/WorkDescription.tsx",
        message: "Remove cross-module dependency from bookfolio to portfolio data layer"
      ),
      finding(
        file: "components/bookfolio/projects/Projects.tsx",
        line: 6,
        message: "Remove cross-module dependency from bookfolio to portfolio data"
      ),
      finding(
        file: "components/bookfolio/summary/Summary.tsx",
        message: "Remove cross-module dependencies from bookfolio to portfolio data"
      ),
      finding(
        file: "components/bookfolio/work/Work.tsx",
        line: 4,
        message: "Remove cross-module dependency from bookfolio to portfolio data"
      )
    ]
  end

  describe "acceptance: one recurring issue, one entry" do
    test "collapses a habit reported across five files into a single pattern" do
      {[pattern], individual} = FindingGrouper.partition(cross_module_findings())

      assert individual == []
      assert pattern.count == 5
      assert pattern.files == 5
      assert pattern.category == "architecture"
      assert pattern.severity == :medium
      assert pattern.message =~ "Remove cross-module dependency"

      # Every location is kept, so the author can still find each one.
      assert Enum.map(pattern.locations, & &1.file) == [
               "components/bookfolio/components/ProjectDescription.tsx",
               "components/bookfolio/components/WorkDescription.tsx",
               "components/bookfolio/projects/Projects.tsx",
               "components/bookfolio/summary/Summary.tsx",
               "components/bookfolio/work/Work.tsx"
             ]

      assert Enum.map(pattern.locations, & &1.line) == [1, 1, 6, 1, 4]
    end

    test "leaves unrelated findings alone alongside a pattern" do
      one_off = finding(file: "app/page.tsx", message: "Rename variable to avoid shadowing")

      {[pattern], individual} = FindingGrouper.partition([one_off | cross_module_findings()])

      assert pattern.count == 5
      assert individual == [one_off]
    end

    test "matches messages that differ only in quoting and punctuation" do
      findings =
        for file <- ["a.tsx", "b.tsx", "c.tsx"] do
          finding(
            file: file,
            category: "readability",
            message: "Remove unused 'props' parameter from component."
          )
        end

      findings =
        List.update_at(findings, 1, fn f ->
          %{f | message: "Remove unused props parameter from component"}
        end)

      assert {[pattern], []} = FindingGrouper.partition(findings)
      assert pattern.count == 3
    end
  end

  describe "what must not be grouped" do
    test "two occurrences are a coincidence, not a pattern" do
      findings = Enum.take(cross_module_findings(), 2)

      assert {[], individual} = FindingGrouper.partition(findings)
      assert length(individual) == 2
    end

    test "different issues that share words stay apart" do
      findings = [
        finding(file: "a.ex", message: "Remove unused import"),
        finding(file: "b.ex", message: "Remove unused import"),
        finding(file: "c.ex", message: "Remove unused variable"),
        finding(file: "d.ex", message: "Remove unused variable")
      ]

      assert {[], individual} = FindingGrouper.partition(findings)
      assert length(individual) == 4
    end

    test "the same sentence in different categories is two issues" do
      findings = [
        finding(file: "a.ex", category: "bugs", message: "Validate the input"),
        finding(file: "b.ex", category: "bugs", message: "Validate the input"),
        finding(file: "c.ex", category: "security", message: "Validate the input"),
        finding(file: "d.ex", category: "security", message: "Validate the input")
      ]

      assert {[], individual} = FindingGrouper.partition(findings)
      assert length(individual) == 4
    end
  end

  describe "the pattern's representative" do
    test "takes the headline the agents used most often" do
      findings = [
        finding(file: "a.ex", message: "Remove cross-module dependency from bookfolio"),
        finding(file: "b.ex", message: "Remove cross-module dependency from bookfolio to data"),
        finding(file: "c.ex", message: "Remove cross-module dependency from bookfolio to data")
      ]

      assert {[pattern], []} = FindingGrouper.partition(findings)
      assert pattern.message == "Remove cross-module dependency from bookfolio to data"
    end

    test "reports the worst severity in the group, not the first" do
      findings = [
        finding(file: "a.ex", severity: :low, message: "Extract the shared type"),
        finding(file: "b.ex", severity: :high, message: "Extract the shared type"),
        finding(file: "c.ex", severity: :low, message: "Extract the shared type")
      ]

      assert {[pattern], []} = FindingGrouper.partition(findings)
      assert pattern.severity == :high
    end

    test "prefers the best-explained finding's reasoning" do
      findings = [
        finding(file: "a.ex", message: "Extract the shared type", reasoning: "short"),
        finding(file: "b.ex", message: "Extract the shared type", reasoning: "a much longer why"),
        finding(file: "c.ex", message: "Extract the shared type", reasoning: "short")
      ]

      assert {[pattern], []} = FindingGrouper.partition(findings)
      assert pattern.reasoning == "a much longer why"
    end

    test "counts distinct files, not occurrences" do
      findings =
        for line <- [1, 5, 9], do: finding(file: "a.ex", line: line, message: "Same nit here")

      assert {[pattern], []} = FindingGrouper.partition(findings)
      assert pattern.count == 3
      assert pattern.files == 1
    end
  end

  describe "order and options" do
    test "keeps individual findings in their input order, so a ranked list stays ranked" do
      findings = [
        finding(file: "high.ex", severity: :high, message: "First and worst"),
        finding(file: "a.ex", message: "Remove cross-module dependency"),
        finding(file: "mid.ex", message: "Something else entirely"),
        finding(file: "b.ex", message: "Remove cross-module dependency"),
        finding(file: "c.ex", message: "Remove cross-module dependency")
      ]

      {[_pattern], individual} = FindingGrouper.partition(findings)

      assert Enum.map(individual, & &1.file) == ["high.ex", "mid.ex"]
    end

    test "honours a different occurrence threshold" do
      findings = Enum.take(cross_module_findings(), 2)

      assert {[pattern], []} = FindingGrouper.partition(findings, min_occurrences: 2)
      assert pattern.count == 2
    end

    test "honours a stricter similarity threshold" do
      # At 1.0 only identical wording groups, so the two "…data layer"
      # findings fall below the default threshold of three.
      assert {[], individual} = FindingGrouper.partition(cross_module_findings(), similarity: 1.0)
      assert length(individual) == 5
    end
  end

  describe "degenerate input" do
    test "returns nothing for no findings" do
      assert FindingGrouper.partition([]) == {[], []}
    end

    test "does not group findings with no message" do
      findings = for file <- ["a.ex", "b.ex", "c.ex"], do: %AgentFinding{file: file, line: 1}

      assert {[], individual} = FindingGrouper.partition(findings)
      assert length(individual) == 3
    end

    test "tolerates a missing category" do
      findings =
        for file <- ["a.ex", "b.ex", "c.ex"] do
          %AgentFinding{file: file, line: 1, category: nil, message: "Same problem everywhere"}
        end

      assert {[pattern], []} = FindingGrouper.partition(findings)
      assert pattern.category == "unknown"
    end
  end
end
