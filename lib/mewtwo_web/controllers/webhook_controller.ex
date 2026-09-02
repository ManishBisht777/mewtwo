defmodule MewtwoWeb.WebhookController do
  use MewtwoWeb, :controller

  @spec github_app_webhook(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def github_app_webhook(conn, _params) do
    # Get raw body
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Get signature header
    signature = Enum.find_value(conn.req_headers, fn {k, v} ->
      if k == "x-hub-signature-256" do
        v
      end
    end)

    # Verify signature
    if Mewtwo.GithubApp.verify_webhook_signature(body, signature) do
      # Parse JSON payload
      {:ok, payload} = Jason.decode(body)

      # Handle PR events
      if payload["pull_request"] do
        action = payload["action"]
        pr_number = payload["pull_request"]["number"]
        pr_title = payload["pull_request"]["title"]
        repo = payload["repository"]["full_name"]

        # Log "hello"
        IO.puts("hello")
        IO.puts("Event: #{action} | Repo: #{repo} | PR ##{pr_number}: #{pr_title}")
      end

      send_resp(conn, 200, "")
    else
      send_resp(conn, 401, "Unauthorized")
    end
  end
end
