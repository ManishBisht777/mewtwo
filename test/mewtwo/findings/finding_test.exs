defmodule Mewtwo.Findings.FindingTest do
  use Mewtwo.DataCase, async: false

  alias Mewtwo.Review
  alias Mewtwo.Findings.{AgentFinding, Finding}

  defp review do
    %Review{
      pr_id: System.unique_integer([:positive]),
      repo: "acme/web",
      status: "complete",
      triggered_at: DateTime.utc_now()
    }
    |> Repo.insert!()
  end

  defp finding(attrs) do
    struct!(
      %AgentFinding{
        file: "lib/a.ex",
        line: 1,
        severity: :high,
        confidence: :medium,
        category: "bugs",
        message: "m",
        reasoning: "r",
        agent_name: "bugs",
        sources: ["bugs"]
      },
      attrs
    )
  end

  describe "record/3" do
    test "stores both audiences and can be queried by review_id" do
      review = review()

      Finding.record(review.id, [finding(line: 1)], [finding(line: 2, severity: :low)])

      assert [author, reviewer] = Finding.for_review(review.id)
      assert author.audience == "author"
      assert author.severity == "high"
      assert author.confidence == "medium"
      assert author.agent_name == "bugs"
      assert reviewer.audience == "reviewer"
      assert reviewer.severity == "low"
    end

    test "does not leak findings between reviews" do
      one = review()
      two = review()

      Finding.record(one.id, [finding([])], [])
      Finding.record(two.id, [finding([]), finding(line: 2)], [])

      assert length(Finding.for_review(one.id)) == 1
      assert length(Finding.for_review(two.id)) == 2
    end

    test "replaces the previous rows so a re-run does not double-count" do
      review = review()

      Finding.record(review.id, [finding([]), finding(line: 2)], [])
      Finding.record(review.id, [finding([])], [])

      assert length(Finding.for_review(review.id)) == 1
    end

    test "a review with no findings stores no rows" do
      review = review()

      assert {0, nil} = Finding.record(review.id, [], [])
      assert Finding.for_review(review.id) == []
    end
  end

  describe "source_of/1" do
    test "an agent and a tool agreeing is 'both' — the tool agreement tier" do
      assert Finding.source_of(finding(sources: ["security", "gitleaks"])) == "both"
    end

    test "a tool alone keeps the tool's name" do
      assert Finding.source_of(finding(sources: ["gitleaks"], agent_name: nil)) == "gitleaks"
    end

    test "agents alone, or no sources at all, is 'agent'" do
      assert Finding.source_of(finding(sources: ["bugs", "perf"])) == "agent"
      assert Finding.source_of(finding(sources: [])) == "agent"
    end
  end
end
