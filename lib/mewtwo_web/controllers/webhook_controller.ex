defmodule MewtwoWeb.WebhookController do
  use MewtwoWeb, :controller

  alias Mewtwo.Workers.ReviewWorker
  alias Oban

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

       # Only handle label events with "need-zacian-review"
       if payload["action"] == "labeled" and payload["label"]["name"] == "initial-review" do
      handle_review_label(payload)
    end

    # Also trigger on PR sync/update if label is already attached
    if payload["action"] == "synchronize" and has_review_label?(payload) do
      IO.puts("PR updated, re-running review...")
      handle_review_label(payload)
    end

      send_resp(conn, 202, "")
    else
      send_resp(conn, 401, "Unauthorized")
    end
  end

 defp handle_review_label(payload) do
  pr_number = payload["pull_request"]["number"]
  repo = payload["repository"]["full_name"]
  pr_id = payload["pull_request"]["id"]

  IO.puts("Enqueueing review for PR ##{pr_number} in #{repo}")

  %{
    pr_id: pr_id,
    pr_number: pr_number,
    repo: repo
  }
  |> ReviewWorker.new()
  |> Oban.insert!()
end

  defp has_review_label?(payload) do
  labels = payload["pull_request"]["labels"] || []
  Enum.any?(labels, fn label -> label["name"] == "" end)
end

end
