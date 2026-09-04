defmodule Mewtwo.DashboardTest do
  use Mewtwo.DataCase, async: false

  alias Mewtwo.{Dashboard, Review}
  alias Mewtwo.Findings.{AgentFinding, Finding}

  defp insert_review(attrs) do
    %Review{
      pr_id: System.unique_integer([:positive]),
      repo: "acme/web",
      status: "complete",
      triggered_at: DateTime.utc_now()
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp insert_findings(attrs) do
    review = insert_review(Keyword.take(attrs, [:triggered_at, :repo]))

    Finding.record(
      review.id,
      Keyword.get(attrs, :author, []),
      Keyword.get(attrs, :reviewer, [])
    )

    review
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

  defp job(attrs) do
    %Oban.Job{worker: "Mewtwo.Workers.ReviewWorker", queue: "reviews", state: "available"}
    |> struct!(attrs)
    |> Repo.insert!()
  end

  describe "totals/1" do
    test "sums tokens and cost over the window" do
      insert_review(cost_usd: 0.10, input_tokens: 1000, output_tokens: 100)
      insert_review(cost_usd: 0.20, input_tokens: 2000, output_tokens: 200)

      totals = Dashboard.totals(days: 7)

      assert totals.runs == 2
      assert totals.input == 3000
      assert totals.output == 300
      assert_in_delta totals.cost, 0.30, 0.000001
    end

    test "excludes runs outside the window" do
      insert_review(triggered_at: DateTime.add(DateTime.utc_now(), -8, :day), input_tokens: 999)

      assert %{runs: 0, input: 0, cost: nil} = Dashboard.totals(days: 7)
    end

    test "counts failures separately but still counts them as runs" do
      insert_review(status: "failed", error: ":diff_too_large")
      insert_review(status: "complete")

      assert %{runs: 2, failed: 1} = Dashboard.totals()
    end

    test "reports cost as nil rather than zero when no run had rates" do
      insert_review(cost_usd: nil, input_tokens: 500)

      assert %{cost: nil, input: 500} = Dashboard.totals()
    end
  end

  describe "by_repo/1" do
    test "groups spend by repo, most expensive first" do
      insert_review(repo: "acme/api", cost_usd: 0.05)
      insert_review(repo: "acme/web", cost_usd: 0.30)
      insert_review(repo: "acme/web", cost_usd: 0.10)

      assert [%{repo: "acme/web", runs: 2} = web, %{repo: "acme/api", runs: 1}] =
               Dashboard.by_repo()

      assert_in_delta web.cost, 0.40, 0.000001
    end
  end

  describe "in_flight/0" do
    test "reads liveness from the Oban job, not from the review row" do
      alive = job(state: "executing")
      dead = job(state: "discarded")

      insert_review(status: "pending", stage: "agents", oban_job_id: alive.id, repo: "a/live")
      insert_review(status: "pending", stage: "agents", oban_job_id: dead.id, repo: "a/dead")
      insert_review(status: "pending", stage: "fetch", oban_job_id: nil, repo: "a/zombie")

      by_repo = Map.new(Dashboard.in_flight(), &{&1.repo, &1.liveness})

      assert by_repo == %{"a/live" => :running, "a/dead" => :stalled, "a/zombie" => :stalled}
    end

    test "ignores finished runs" do
      insert_review(status: "complete")
      insert_review(status: "failed")

      assert Dashboard.in_flight() == []
    end
  end

  describe "queued/0" do
    test "counts waiting review jobs, which have no review row yet" do
      job(state: "available")
      job(state: "scheduled")
      job(state: "completed")
      job(state: "available", queue: "default")

      assert Dashboard.queued() == 2
    end
  end

  describe "recent/1" do
    test "returns finished runs newest first, capped by limit" do
      now = DateTime.utc_now()
      insert_review(repo: "old", triggered_at: DateTime.add(now, -60, :second))
      insert_review(repo: "new", triggered_at: now)
      insert_review(repo: "running", status: "pending")

      assert [%{repo: "new"}, %{repo: "old"}] = Dashboard.recent()
      assert [%{repo: "new"}] = Dashboard.recent(limit: 1)
    end
  end

  describe "daily/1" do
    test "fills quiet days rather than skipping them" do
      insert_review(cost_usd: 0.5)

      days = Dashboard.daily(days: 7)

      assert length(days) == 8
      assert List.last(days).runs == 1
      assert Enum.any?(days, &(&1.runs == 0 and is_nil(&1.cost)))
    end
  end

  describe "compression_trend/1" do
    test "reads percent saved from metadata and skips runs without it" do
      insert_review(
        author_findings: %{"metadata" => %{"compression" => %{"ratio" => 0.25}}},
        triggered_at: DateTime.add(DateTime.utc_now(), -10, :second)
      )

      insert_review(author_findings: %{"count" => 0})

      assert [saved] = Dashboard.compression_trend()
      assert_in_delta saved, 75.0, 0.001
    end
  end

  describe "compression/1 (M1)" do
    test "averages percent saved and totals the tokens compression removed" do
      insert_review(
        author_findings: %{
          "metadata" => %{
            "compression" => %{
              "ratio" => 0.25,
              "original_tokens" => 1000,
              "compressed_tokens" => 250,
              "truncated_sections" => 2
            }
          }
        }
      )

      insert_review(
        author_findings: %{
          "metadata" => %{
            "compression" => %{
              "ratio" => 0.75,
              "original_tokens" => 400,
              "compressed_tokens" => 300,
              "truncated_sections" => 0
            }
          }
        }
      )

      stats = Dashboard.compression()

      assert stats.runs == 2
      assert_in_delta stats.avg_saved, 50.0, 0.001
      assert stats.original == 1400
      assert stats.compressed == 550
      assert stats.dropped == 2
    end

    test "skips runs that never compressed rather than averaging them as zero" do
      insert_review(status: "failed", author_findings: nil)
      insert_review(author_findings: %{"count" => 0})

      assert %{runs: 0, avg_saved: nil} = Dashboard.compression()
    end
  end

  describe "agreement/1 (M3)" do
    test "reports the rate once a tool has actually contributed findings" do
      insert_review(
        author_findings: %{
          "metadata" => %{"tool_agreement_rate" => 0.4, "gitleaks_findings_count" => 3}
        }
      )

      assert %{tool_findings: 3} = stats = Dashboard.agreement()
      assert_in_delta stats.rate, 0.4, 0.001
    end

    test "hides the rate while gitleaks has produced nothing, since 0% would be fake" do
      insert_review(
        author_findings: %{
          "metadata" => %{"tool_agreement_rate" => 0.0, "gitleaks_findings_count" => 0}
        }
      )

      assert %{rate: nil, tool_findings: 0} = Dashboard.agreement()
    end
  end

  describe "confidence_counts/1 (M3)" do
    test "counts findings per tier over the window" do
      insert_findings(
        author: [finding(confidence: :high), finding(confidence: :medium, line: 2)],
        reviewer: [finding(confidence: :low, line: 3)]
      )

      assert Dashboard.confidence_counts() == %{"high" => 1, "medium" => 1, "low" => 1}
    end
  end

  describe "secrets_by_type/1 (M2)" do
    test "counts tool findings by category and how many an agent also flagged" do
      insert_findings(
        author: [
          finding(category: "secrets", sources: ["gitleaks"], agent_name: nil),
          finding(category: "secrets", sources: ["security", "gitleaks"], line: 2),
          finding(category: "bugs", line: 3)
        ]
      )

      assert [%{category: "secrets", count: 2, agreed: 1}] = Dashboard.secrets_by_type()
    end

    test "is empty when no tool ran, so the section can be hidden" do
      insert_findings(author: [finding([])])

      assert Dashboard.secrets_by_type() == []
    end
  end

  describe "agent_stats/1 (M4)" do
    test "folds per-agent findings, latency and failures across runs" do
      insert_review(
        author_findings: %{
          "metadata" => %{
            "per_agent" => %{
              "bugs" => %{
                "findings" => 3,
                "ms" => 1000,
                "error" => nil,
                "usage" => %{"input_tokens" => 100, "output_tokens" => 10}
              },
              "perf" => %{"findings" => 0, "ms" => 500, "error" => "timeout"}
            }
          }
        }
      )

      insert_review(
        author_findings: %{
          "metadata" => %{
            "per_agent" => %{"bugs" => %{"findings" => 1, "ms" => 3000, "error" => nil}}
          }
        }
      )

      insert_review(author_findings: nil)

      assert [bugs, perf] = Dashboard.agent_stats()

      assert bugs == %{
               agent: "bugs",
               runs: 2,
               findings: 4,
               errors: 0,
               avg_ms: 2000,
               input: 100,
               output: 10
             }

      assert perf.errors == 1
      assert perf.findings == 0
    end
  end

  describe "latency/1 (M4)" do
    test "averages finished runs only" do
      now = DateTime.utc_now()
      insert_review(triggered_at: now, completed_at: DateTime.add(now, 10, :second))
      insert_review(triggered_at: now, completed_at: DateTime.add(now, 30, :second))
      insert_review(status: "pending", completed_at: nil)

      stats = Dashboard.latency()

      assert stats.runs == 2
      assert_in_delta stats.avg, 20.0, 0.001
      assert_in_delta stats.max, 30.0, 0.001
    end

    test "reports nils rather than zero when nothing finished in the window" do
      insert_review(status: "pending", completed_at: nil)

      assert %{runs: 0, avg: nil, max: nil} = Dashboard.latency()
    end
  end

  describe "sparkline/3" do
    test "scales from zero so a flat high series reads as flat and high" do
      assert Dashboard.sparkline([5, 5, 5], 100, 10) == "0.0,0.0 50.0,0.0 100.0,0.0"
    end

    test "puts the peak at the top and zero at the baseline" do
      assert Dashboard.sparkline([0, 10], 100, 10) == "0.0,10.0 100.0,0.0"
    end

    test "survives an all-zero series without dividing by zero" do
      assert Dashboard.sparkline([0, 0], 100, 10) == "0.0,10.0 100.0,10.0"
    end

    test "renders a single point as a flat line, and nothing for no points" do
      assert Dashboard.sparkline([3], 100, 10) == "0.0,0.0 100.0,0.0"
      assert Dashboard.sparkline([]) == ""
    end
  end
end
