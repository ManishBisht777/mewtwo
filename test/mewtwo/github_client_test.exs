defmodule Mewtwo.GithubClientTest do
  use ExUnit.Case, async: false

  alias Mewtwo.GithubClient

  # Requests are served by an in-process plug via Req's :plug option, so these
  # tests never touch the network.

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # Echoes the request headers back so header handling can be asserted.
  defp echo_headers_plug do
    fn conn -> json(conn, 200, %{"headers" => Map.new(conn.req_headers)}) end
  end

  defp with_token(token, fun) do
    old = System.get_env("GITHUB_TOKEN")

    try do
      if token, do: System.put_env("GITHUB_TOKEN", token), else: System.delete_env("GITHUB_TOKEN")
      fun.()
    after
      if old, do: System.put_env("GITHUB_TOKEN", old), else: System.delete_env("GITHUB_TOKEN")
    end
  end

  describe "authentication" do
    test "sends no Authorization header when GITHUB_TOKEN is unset" do
      with_token(nil, fn ->
        {:ok, %{"headers" => headers}} = GithubClient.get("/x", plug: echo_headers_plug())

        refute Map.has_key?(headers, "authorization")
      end)
    end

    test "sends no Authorization header when GITHUB_TOKEN is blank" do
      # A literal `Authorization: token ` is rejected by GitHub as 401 rather
      # than falling back to anonymous access.
      for blank <- ["", "   "] do
        with_token(blank, fn ->
          {:ok, %{"headers" => headers}} = GithubClient.get("/x", plug: echo_headers_plug())

          refute Map.has_key?(headers, "authorization")
        end)
      end
    end

    test "sends the Authorization header when GITHUB_TOKEN is set" do
      with_token("ghp_example", fn ->
        {:ok, %{"headers" => headers}} = GithubClient.get("/x", plug: echo_headers_plug())

        assert headers["authorization"] == "token ghp_example"
      end)
    end

    test "trims surrounding whitespace from the token" do
      with_token("  ghp_example  ", fn ->
        {:ok, %{"headers" => headers}} = GithubClient.get("/x", plug: echo_headers_plug())

        assert headers["authorization"] == "token ghp_example"
      end)
    end
  end

  describe "header merging" do
    test "sends the default Accept and API version" do
      with_token(nil, fn ->
        {:ok, %{"headers" => headers}} = GithubClient.get("/x", plug: echo_headers_plug())

        assert headers["accept"] == "application/vnd.github+json"
        assert headers["x-github-api-version"] == "2022-11-28"
      end)
    end

    test "a caller-supplied Accept replaces the default rather than being appended" do
      plug = fn conn ->
        accepts = for {"accept", v} <- conn.req_headers, do: v
        json(conn, 200, %{"accepts" => accepts})
      end

      with_token(nil, fn ->
        {:ok, %{"accepts" => accepts}} =
          GithubClient.get("/x",
            headers: [{"Accept", "application/vnd.github.v3.diff"}],
            plug: plug
          )

        assert accepts == ["application/vnd.github.v3.diff"]
      end)
    end

    test "overrides Accept case-insensitively" do
      plug = fn conn ->
        accepts = for {"accept", v} <- conn.req_headers, do: v
        json(conn, 200, %{"accepts" => accepts})
      end

      with_token(nil, fn ->
        {:ok, %{"accepts" => accepts}} =
          GithubClient.get("/x", headers: [{"accept", "text/plain"}], plug: plug)

        assert accepts == ["text/plain"]
      end)
    end

    test "keeps default headers the caller did not override" do
      with_token(nil, fn ->
        {:ok, %{"headers" => headers}} =
          GithubClient.get("/x",
            headers: [{"Accept", "application/vnd.github.v3.diff"}],
            plug: echo_headers_plug()
          )

        assert headers["x-github-api-version"] == "2022-11-28"
      end)
    end
  end

  describe "status handling" do
    setup do
      # These assertions are about status, not auth.
      old = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> if old, do: System.put_env("GITHUB_TOKEN", old) end)
    end

    test "returns the body on success" do
      plug = fn conn -> json(conn, 200, %{"title" => "a pr"}) end

      assert {:ok, %{"title" => "a pr"}} = GithubClient.get("/x", plug: plug)
    end

    test "returns a raw string body unchanged for a diff media type" do
      diff = "diff --git a/a.ex b/a.ex\n+hello\n"

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/vnd.github.v3.diff")
        |> Plug.Conn.send_resp(200, diff)
      end

      assert {:ok, ^diff} = GithubClient.get("/x", plug: plug)
    end

    test "maps 404 to :not_found instead of a successful error payload" do
      plug = fn conn -> json(conn, 404, %{"message" => "Not Found"}) end

      assert {:error, {:not_found, "Not Found"}} = GithubClient.get("/x", plug: plug)
    end

    test "maps 401 to :unauthorized" do
      plug = fn conn -> json(conn, 401, %{"message" => "Bad credentials"}) end

      assert {:error, {:unauthorized, "Bad credentials"}} = GithubClient.get("/x", plug: plug)
    end

    test "maps an exhausted rate limit to :rate_limited" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> json(403, %{"message" => "API rate limit exceeded"})
      end

      assert {:error, {:rate_limited, "API rate limit exceeded", seconds}} =
               GithubClient.get("/x", plug: plug)

      # No reset header on this response, so it falls back to a minute.
      assert seconds == 60
    end

    test "reports seconds until the quota resets" do
      reset_at = System.os_time(:second) + 900

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", to_string(reset_at))
        |> json(403, %{"message" => "API rate limit exceeded"})
      end

      assert {:error, {:rate_limited, _, seconds}} = GithubClient.get("/x", plug: plug)
      assert_in_delta seconds, 900, 5
    end

    test "prefers retry-after, which secondary limits use" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("retry-after", "45")
        |> Plug.Conn.put_resp_header(
          "x-ratelimit-reset",
          to_string(System.os_time(:second) + 900)
        )
        |> json(403, %{"message" => "Secondary rate limit"})
      end

      assert {:error, {:rate_limited, _, 45}} = GithubClient.get("/x", plug: plug)
    end

    test "maps a 403 that is not a rate limit to :unauthorized" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "58")
        |> json(403, %{"message" => "Resource not accessible"})
      end

      assert {:error, {:unauthorized, "Resource not accessible"}} =
               GithubClient.get("/x", plug: plug)
    end

    test "maps other failures to :http_error with the status" do
      plug = fn conn -> json(conn, 500, %{"message" => "Server Error"}) end

      # retry: false — Req retries 5xx by default, which is wanted in
      # production but adds seconds of backoff to this assertion.
      assert {:error, {:http_error, 500, "Server Error"}} =
               GithubClient.get("/x", plug: plug, retry: false)
    end
  end

  describe "get_paginated/2" do
    setup do
      old = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> if old, do: System.put_env("GITHUB_TOKEN", old) end)
    end

    test "returns a single page as-is" do
      plug = fn conn -> json(conn, 200, [%{"n" => 1}]) end

      assert {:ok, [%{"n" => 1}]} = GithubClient.get_paginated("/x", plug: plug)
    end

    test "follows Link rel=next and concatenates pages in order" do
      plug = fn conn ->
        case conn.query_string do
          "page=2" ->
            json(conn, 200, [%{"n" => 2}])

          _ ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<http://localhost/x?page=2>; rel="next", <http://localhost/x?page=2>; rel="last")
            )
            |> json(200, [%{"n" => 1}])
        end
      end

      assert {:ok, [%{"n" => 1}, %{"n" => 2}]} = GithubClient.get_paginated("/x", plug: plug)
    end

    test "propagates an error from a later page" do
      plug = fn conn ->
        case conn.query_string do
          "page=2" ->
            json(conn, 404, %{"message" => "Not Found"})

          _ ->
            conn
            |> Plug.Conn.put_resp_header("link", ~s(<http://localhost/x?page=2>; rel="next"))
            |> json(200, [%{"n" => 1}])
        end
      end

      assert {:error, {:not_found, "Not Found"}} = GithubClient.get_paginated("/x", plug: plug)
    end

    test "stops at the page cap instead of walking every page" do
      # An always-has-a-next-page endpoint, as a listing endpoint effectively is.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("link", ~s(<http://localhost/x?page=99>; rel="next"))
        |> json(200, [%{"n" => 1}])
      end

      assert {:ok, items} = GithubClient.get_paginated("/x", plug: plug, max_pages: 3)
      assert length(items) == 3
    end

    test "defaults to a bounded number of pages" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("link", ~s(<http://localhost/x?page=99>; rel="next"))
        |> json(200, [%{"n" => 1}])
      end

      assert {:ok, items} = GithubClient.get_paginated("/x", plug: plug)
      assert length(items) == :counters.get(counter, 1)
      assert length(items) <= 10
    end

    test "errors when the body is not a JSON array" do
      plug = fn conn -> json(conn, 200, %{"message" => "not a list"}) end

      assert {:error, {:unexpected_body, reason}} = GithubClient.get_paginated("/x", plug: plug)
      assert reason =~ "expected a JSON array"
    end
  end

  describe "post/3" do
    test "sends the body as JSON with the default headers and auth" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        json(conn, 201, %{
          "method" => conn.method,
          "path" => conn.request_path,
          "sent" => Jason.decode!(body),
          "headers" => Map.new(conn.req_headers)
        })
      end

      with_token("ghp_example", fn ->
        assert {:ok, echo} =
                 GithubClient.post("/repos/o/r/pulls/1/reviews", %{event: "COMMENT"}, plug: plug)

        assert echo["method"] == "POST"
        assert echo["path"] == "/repos/o/r/pulls/1/reviews"
        assert echo["sent"] == %{"event" => "COMMENT"}
        assert echo["headers"]["authorization"] == "token ghp_example"
        assert echo["headers"]["accept"] == "application/vnd.github+json"
      end)
    end

    test "maps a rejected body to an error instead of returning it as success" do
      # GitHub answers an out-of-diff comment line with 422 and a normal JSON
      # body; without the status check it would flow on as if it had posted.
      plug = fn conn -> json(conn, 422, %{"message" => "line must be part of the diff"}) end

      assert {:error, {:http_error, 422, message}} = GithubClient.post("/x", %{}, plug: plug)
      assert message =~ "part of the diff"
    end

    test "reports whether a usable token is present" do
      with_token(nil, fn -> refute GithubClient.authenticated?() end)
      with_token("   ", fn -> refute GithubClient.authenticated?() end)
      with_token("ghp_example", fn -> assert GithubClient.authenticated?() end)
    end
  end
end
