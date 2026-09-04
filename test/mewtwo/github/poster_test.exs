defmodule Mewtwo.Github.PosterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Github.Poster

  # Requests are served by an in-process plug via Req's :plug option, so these
  # tests never touch GitHub.

  setup do
    old = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "ghp_test")

    on_exit(fn ->
      if old, do: System.put_env("GITHUB_TOKEN", old), else: System.delete_env("GITHUB_TOKEN")
    end)

    :ok
  end

  defp finding(opts) do
    {:ok, f} =
      AgentFinding.new(
        Keyword.get(opts, :file, "lib/a.ex"),
        Keyword.get(opts, :line, 10),
        Keyword.get(opts, :severity, :high),
        Keyword.get(opts, :confidence, :high),
        "bugs",
        Keyword.get(opts, :message, "handles nil badly"),
        "because the caller can pass nil",
        agent_name: "bugs",
        sources: ["bugs"]
      )

    f
  end

  # Records each request on the test process and answers with `responses`,
  # one per call, so a retry can be given a different status than the first try.
  defp recording_plug(responses) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      {status, response} = Enum.at(responses, n) || List.last(responses)

      send(test, {:request, conn.method, conn.request_path, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end
  end

  defp post(findings, reviewer \\ [], responses) do
    Poster.post_review("owner/name", 7, findings, reviewer, %{total_agents: 5},
      request_opts: [plug: recording_plug(responses)]
    )
  end

  describe "acceptance: posting a review" do
    test "posts the summary and inline comments as one review" do
      assert {:ok, result} = post([finding(line: 10), finding(line: 20)], [{201, %{"id" => 99}}])

      assert result == %{review_id: 99, inline_comments: 2, fallback: false}

      assert_received {:request, "POST", "/repos/owner/name/pulls/7/reviews", payload}

      assert payload["event"] == "COMMENT"
      assert payload["body"] =~ "Mewtwo review"
      assert [%{"path" => "lib/a.ex", "line" => 10, "side" => "RIGHT"}, _] = payload["comments"]
      assert length(payload["comments"]) == 2
    end

    test "never requests changes, which would block the merge on model output" do
      assert {:ok, _} = post([finding([])], [{201, %{"id" => 1}}])

      assert_received {:request, _, _, %{"event" => "COMMENT"}}
    end

    test "posts the summary alone when there is nothing to comment on" do
      assert {:ok, result} = post([], [{201, %{"id" => 5}}])

      assert result == %{review_id: 5, inline_comments: 0, fallback: false}

      assert_received {:request, _, _, payload}
      # An empty `comments` array is rejected by GitHub, so the key is omitted.
      refute Map.has_key?(payload, "comments")
      assert payload["body"] =~ "No findings"
    end

    test "tolerates a response without an id rather than crashing after posting" do
      assert {:ok, %{review_id: nil}} = post([], [{201, %{}}])
    end
  end

  describe "findings the agents repeated across files" do
    test "go in the summary instead of becoming one comment each" do
      repeated =
        for file <- ["a.tsx", "b.tsx", "c.tsx"] do
          finding(file: file, message: "Remove cross-module dependency from bookfolio")
        end

      one_off = finding(file: "app/page.tsx", line: 3, message: "a lone problem")

      assert {:ok, result} = post([one_off | repeated], [{201, %{"id" => 1}}])

      # One comment for the one-off finding; the three repeats are one summary
      # entry rather than three comments saying the same sentence.
      assert result.inline_comments == 1

      assert_received {:request, _, _, payload}

      assert [%{"path" => "app/page.tsx"}] = payload["comments"]
      assert payload["body"] =~ "Repeated across the diff"
      assert payload["body"] =~ "3× in 3 files"
      assert payload["body"] =~ "`a.tsx:10`"
    end

    test "posts the summary alone when every finding is part of a pattern" do
      repeated =
        for file <- ["a.tsx", "b.tsx", "c.tsx"] do
          finding(file: file, message: "Remove cross-module dependency from bookfolio")
        end

      assert {:ok, %{inline_comments: 0, fallback: false}} = post(repeated, [{201, %{"id" => 1}}])

      assert_received {:request, _, _, payload}
      refute Map.has_key?(payload, "comments")
      assert payload["body"] =~ "Repeated across the diff"
    end
  end

  describe "inline comments GitHub will not accept" do
    test "retries with the findings folded into the summary" do
      responses = [
        {422, %{"message" => "line must be part of the diff"}},
        {201, %{"id" => 12}}
      ]

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   post([finding(line: 999, message: "outside the hunk")], responses)

          assert result == %{review_id: 12, inline_comments: 0, fallback: true}
        end)

      assert log =~ "retrying with them in the summary"

      # First attempt carried the comment; the retry carried none but kept the
      # finding in the body, so nothing is silently dropped.
      assert_received {:request, _, _, %{"comments" => [_]}}
      assert_received {:request, _, _, retry}

      refute Map.has_key?(retry, "comments")
      assert retry["body"] =~ "outside the hunk"
      assert retry["body"] =~ "lib/a.ex:999"
    end

    test "does not retry a 422 that had no inline comments to blame" do
      log =
        capture_log(fn ->
          assert {:error, {:http_error, 422, _}} = post([], [{422, %{"message" => "nope"}}])
        end)

      assert log =~ "failed"

      assert_received {:request, _, _, _}
      refute_received {:request, _, _, _}
    end

    test "caps the fallback list so the summary body cannot outgrow GitHub's limit" do
      responses = [
        {422, %{"message" => "line must be part of the diff"}},
        {201, %{"id" => 3}}
      ]

      many = for n <- 1..60, do: finding(line: n, message: "finding #{n}")

      capture_log(fn ->
        assert {:ok, %{fallback: true}} = post(many, responses)
      end)

      assert_received {:request, _, _, _}
      assert_received {:request, _, _, retry}

      assert retry["body"] =~ "finding 50"
      refute retry["body"] =~ "finding 51"
      assert retry["body"] =~ "and 10 more on the review record"
    end

    test "does not repeat a pattern in the fallback list" do
      responses = [
        {422, %{"message" => "line must be part of the diff"}},
        {201, %{"id" => 8}}
      ]

      repeated =
        for file <- ["a.tsx", "b.tsx", "c.tsx"] do
          finding(file: file, message: "Remove cross-module dependency from bookfolio")
        end

      one_off = finding(file: "app/page.tsx", line: 3, message: "a lone problem")

      capture_log(fn ->
        assert {:ok, %{fallback: true}} = post([one_off | repeated], responses)
      end)

      assert_received {:request, _, _, _}
      assert_received {:request, _, _, retry}

      assert retry["body"] =~ "a lone problem"
      # Already in the summary's pattern section; listing it again would show
      # it twice in one comment.
      assert length(String.split(retry["body"], "Remove cross-module dependency")) == 2
    end

    test "gives up when the fallback is rejected too" do
      responses = [
        {422, %{"message" => "line must be part of the diff"}},
        {422, %{"message" => "still no"}}
      ]

      log =
        capture_log(fn ->
          assert {:error, {:http_error, 422, _}} = post([finding([])], responses)
        end)

      assert log =~ "fallback also failed"
    end
  end

  describe "errors a caller has to tell apart" do
    test "reports a missing token without making a request" do
      System.delete_env("GITHUB_TOKEN")

      log =
        capture_log(fn ->
          assert {:error, {:unauthenticated, message}} =
                   post([finding([])], [{201, %{"id" => 1}}])

          assert message =~ "GITHUB_TOKEN"
        end)

      assert log =~ "cannot be posted"
      refute_received {:request, _, _, _}
    end

    test "propagates an under-scoped token as unauthorized" do
      capture_log(fn ->
        assert {:error, {:unauthorized, _}} =
                 post([finding([])], [{403, %{"message" => "Resource not accessible"}}])
      end)
    end

    test "propagates a rate limit with its wait, so a caller can snooze" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("retry-after", "120")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "rate limited"}))
      end

      capture_log(fn ->
        assert {:error, {:rate_limited, _, 120}} =
                 Poster.post_review("owner/name", 7, [finding([])], [], %{},
                   request_opts: [plug: plug]
                 )
      end)
    end

    test "propagates a missing PR as not found" do
      capture_log(fn ->
        assert {:error, {:not_found, _}} =
                 post([finding([])], [{404, %{"message" => "Not Found"}}])
      end)
    end
  end
end
