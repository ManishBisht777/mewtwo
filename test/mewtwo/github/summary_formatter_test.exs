defmodule Mewtwo.Github.SummaryFormatterTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Github.SummaryFormatter

  defp finding(opts) do
    {:ok, f} =
      AgentFinding.new(
        Keyword.get(opts, :file, "lib/a.ex"),
        Keyword.get(opts, :line, 10),
        Keyword.get(opts, :severity, :medium),
        Keyword.get(opts, :confidence, :medium),
        Keyword.get(opts, :category, "bugs"),
        Keyword.get(opts, :message, "handles nil badly"),
        "because the caller can pass nil",
        agent_name: "bugs",
        sources: Keyword.get(opts, :sources, ["bugs"])
      )

    f
  end

  defp judge_metadata(overrides \\ %{}) do
    Map.merge(
      %{
        total_agents: 5,
        gitleaks_findings_count: 1,
        dedup_count: 4,
        tool_agreement_rate: 0.333
      },
      overrides
    )
  end

  describe "acceptance: the summary a reviewer reads first" do
    test "reports counts by severity, agreement, compression and context" do
      author = [finding(severity: :high), finding(severity: :medium)]
      reviewer = [finding(severity: :low, confidence: :low)]

      summary =
        SummaryFormatter.format(
          author,
          reviewer,
          judge_metadata(%{
            agents: ["bugs", "security"],
            usage: %{input_tokens: 120_000, output_tokens: 3_000, calls: 5},
            compression: %{original_tokens: 400_000, compressed_tokens: 100_000},
            context: %{fetched: 28, skipped: 3, tokens_used: 14_900}
          })
        )

      assert summary =~ "2 findings for you"
      assert summary =~ "1 for reviewers"

      # Severity table
      assert summary =~ "| Severity | For the author | For reviewers |"
      assert summary =~ "| 🔴 High | 1 | 0 |"
      assert summary =~ "| ⚪ Low | 0 | 1 |"

      # Run details
      assert summary =~ "**Agents:** 2 (bugs, security)"
      assert summary =~ "**Tool agreement:** 33%"
      assert summary =~ "**Gitleaks:** 1 finding"
      assert summary =~ "**Duplicates collapsed:** 4"
      assert summary =~ "400,000 → 100,000 diff tokens (75.0% saved)"
      assert summary =~ "28 items fetched, 3 skipped (14,900 tokens)"
      assert summary =~ "120,000 in / 3,000 out tokens over 5 calls"
    end

    test "says so plainly when there is nothing to report" do
      summary = SummaryFormatter.format([], [], judge_metadata())

      assert summary =~ "No findings"
      refute summary =~ "| Severity |"
    end
  end

  describe "reviewer findings" do
    test "lists them collapsed, since they are context rather than a task list" do
      summary = SummaryFormatter.format([], [finding(message: "shadowed variable")], %{})

      assert summary =~ "<details>"
      assert summary =~ "context, not blocking"
      assert summary =~ "shadowed variable"
    end

    test "caps the list and points at the review record for the rest" do
      reviewer = for n <- 1..20, do: finding(line: n, message: "nit #{n}")

      summary = SummaryFormatter.format([], reviewer, %{})

      assert summary =~ "20 findings for reviewers"
      assert summary =~ "nit 12"
      refute summary =~ "nit 13"
      assert summary =~ "and 8 more on the review record"
    end
  end

  describe "findings the agents repeated across files" do
    defp repeated(message, files, opts \\ []) do
      for file <- files, do: finding(Keyword.merge([file: file, message: message], opts))
    end

    test "collapses them into one entry listing every location" do
      author =
        repeated("Remove cross-module dependency from bookfolio to portfolio data", [
          "a.tsx",
          "b.tsx",
          "c.tsx"
        ])

      summary = SummaryFormatter.format(author, [], %{})

      assert summary =~ "### Repeated across the diff"
      assert summary =~ "Remove cross-module dependency"
      assert summary =~ "3× in 3 files"
      assert summary =~ "`a.tsx:10`"
      assert summary =~ "`c.tsx:10`"

      # One entry, not three — the message appears once.
      assert length(String.split(summary, "Remove cross-module dependency")) == 2
    end

    test "caps the location list rather than printing a wall of paths" do
      author = repeated("Remove the unused props parameter", for(n <- 1..14, do: "c#{n}.tsx"))

      summary = SummaryFormatter.format(author, [], %{})

      assert summary =~ "14× in 14 files"
      assert summary =~ "`c10.tsx:10`"
      refute summary =~ "`c11.tsx:10`"
      assert summary =~ "and 4 more"
    end

    test "groups reviewer findings too, on one line with their locations" do
      reviewer =
        repeated("Remove unused 'props' parameter from component", ["a.tsx", "b.tsx", "c.tsx"])

      summary = SummaryFormatter.format([], reviewer, %{})

      assert summary =~ "3× in 3 files"
      assert summary =~ "`a.tsx:10`, `b.tsx:10`, `c.tsx:10`"
      assert length(String.split(summary, "Remove unused")) == 2
    end

    test "counts every finding in the severity table, grouped or not" do
      author =
        repeated("Remove cross-module dependency", ["a.tsx", "b.tsx", "c.tsx"], severity: :high)

      summary = SummaryFormatter.format(author, [], %{})

      assert summary =~ "3 findings for you"
      assert summary =~ "| 🔴 High | 3 | 0 |"
    end

    test "leaves a one-off finding to its inline comment" do
      summary = SummaryFormatter.format([finding(message: "a lone problem")], [], %{})

      refute summary =~ "Repeated across the diff"
      refute summary =~ "a lone problem"
    end
  end

  describe "author findings that cannot be posted inline" do
    test "are listed in the summary rather than lost" do
      unplaceable = %AgentFinding{
        file: "lib/a.ex",
        line: nil,
        severity: :high,
        confidence: :high,
        category: "bugs",
        message: "no line for this one"
      }

      summary = SummaryFormatter.format([finding([]), unplaceable], [], %{})

      assert summary =~ "1 finding without a usable line"
      assert summary =~ "no line for this one"
    end

    test "are not mentioned when every finding got an inline comment" do
      summary = SummaryFormatter.format([finding([])], [], %{})

      refute summary =~ "without a usable line"
      # The inline comment already carries it; repeating it here would show
      # every finding twice on the PR.
      refute summary =~ "handles nil badly"
    end
  end

  describe "partial metadata" do
    test "omits a stat rather than printing a zero that reads as a measurement" do
      summary = SummaryFormatter.format([finding([])], [], %{total_agents: 5})

      assert summary =~ "**Agents:** 5"
      refute summary =~ "Compression"
      refute summary =~ "Tool agreement"
      refute summary =~ "Context"
      refute summary =~ "Model usage"
    end

    test "distinguishes a skipped context stage from an unreported one" do
      assert SummaryFormatter.format([], [], %{context: nil}) =~ "**Context:** skipped"
      refute SummaryFormatter.format([], [], %{}) =~ "**Context:**"
    end

    test "flags dropped files, since a clean review of half a diff is misleading" do
      summary =
        SummaryFormatter.format([], [], %{
          compression: %{
            original_tokens: 400_000,
            compressed_tokens: 100_000,
            truncated_sections: 2
          }
        })

      assert summary =~ "**Not reviewed:** 2 files dropped"
    end

    test "reads metadata that has round-tripped through the reviews table as JSON" do
      summary =
        SummaryFormatter.format([], [], %{
          "total_agents" => 5,
          "tool_agreement_rate" => 0.4,
          "compression" => %{"original_tokens" => 100, "compressed_tokens" => 50}
        })

      assert summary =~ "**Agents:** 5"
      assert summary =~ "**Tool agreement:** 40%"
      assert summary =~ "100 → 50 diff tokens"
    end

    test "counts DynamicContext's own result shape as well as bare counts" do
      summary =
        SummaryFormatter.format([], [], %{
          context: %{
            fetched_context: [%{type: "caller"}, %{type: "test"}],
            skipped_items: [%{type: "docs"}],
            tokens_used: 900
          }
        })

      assert summary =~ "2 items fetched, 1 skipped (900 tokens)"
    end

    test "survives no metadata at all" do
      summary = SummaryFormatter.format([finding([])], [])

      assert summary =~ "Mewtwo review"
      refute summary =~ "Run details"
    end

    test "distinguishes gitleaks finding nothing from gitleaks not running" do
      assert SummaryFormatter.format([], [], %{gitleaks_findings_count: 0}) =~
               "**Gitleaks:** no findings"

      refute SummaryFormatter.format([], [], %{total_agents: 1}) =~ "Gitleaks"
    end
  end
end
