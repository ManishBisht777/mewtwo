defmodule MewtwoWeb.DashboardLiveTest do
  @moduledoc """
  A render smoke test, not a UI spec — the aggregates are asserted in
  `Mewtwo.DashboardTest`. This only catches the crash an empty or a populated
  page would otherwise hit in the browser: a nil where a number was rendered.

  A plain `GET` gets the LiveView's static render, which runs `mount` and the
  full template. `Phoenix.LiveViewTest` would also cover the expand click, but
  it needs a `lazy_html` version that is incompatible with this project's
  LiveView, and one new dependency for one click is not worth it.
  """

  use MewtwoWeb.ConnCase, async: false

  alias Mewtwo.{Repo, Review}
  alias Mewtwo.Findings.{AgentFinding, Finding}

  setup %{conn: conn} do
    System.put_env("DASHBOARD_USER", "admin")
    System.put_env("DASHBOARD_PASSWORD", "secret")

    on_exit(fn ->
      System.delete_env("DASHBOARD_USER")
      System.delete_env("DASHBOARD_PASSWORD")
    end)

    {:ok,
     conn:
       put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("admin", "secret"))}
  end

  test "renders with no runs at all", %{conn: conn} do
    html = conn |> get(~p"/dashboard") |> html_response(200)

    assert html =~ "mewtwo"
    assert html =~ "idle"
  end

  test "renders the metrics sections for a finished run", %{conn: conn} do
    review =
      %Review{
        pr_id: 42,
        repo: "acme/web",
        status: "complete",
        triggered_at: DateTime.utc_now(),
        completed_at: DateTime.add(DateTime.utc_now(), 31, :second),
        input_tokens: 12_400,
        output_tokens: 1100,
        cost_usd: 0.18,
        author_findings: %{
          "count" => 1,
          "metadata" => %{
            "compression" => %{
              "ratio" => 0.24,
              "original_tokens" => 412_000,
              "compressed_tokens" => 98_000,
              "truncated_sections" => 2
            },
            "tool_agreement_rate" => 0.0,
            "gitleaks_findings_count" => 0,
            "per_agent" => %{
              "bugs" => %{
                "findings" => 3,
                "ms" => 8100,
                "error" => nil,
                "usage" => %{"input_tokens" => 12_400, "output_tokens" => 1100}
              }
            }
          }
        }
      }
      |> Repo.insert!()

    Finding.record(
      review.id,
      [
        %AgentFinding{
          file: "lib/a.ex",
          line: 7,
          severity: :high,
          confidence: :medium,
          category: "bugs",
          message: "nil crashes here",
          reasoning: "r",
          agent_name: "bugs",
          sources: ["bugs"]
        }
      ],
      []
    )

    html = conn |> get(~p"/dashboard") |> html_response(200)

    assert html =~ "acme/web"
    assert html =~ "76% saved"
    assert html =~ "31s avg"
    assert html =~ "medium 1"
    assert html =~ "bugs"
    # Structurally 0% until gitleaks lands, so it must not be rendered at all.
    refute html =~ "tool agreement"

    # The one finding recorded is queryable by review, which is what the
    # expand renders.
    assert [%{message: "nil crashes here"}] = Finding.for_review(review.id)
  end
end
