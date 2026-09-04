defmodule MewtwoWeb.WebhookController do
  use MewtwoWeb, :controller

  alias Mewtwo.Workers.ReviewWorker
  alias Oban

  def github_app_webhook(conn, _params) do
    body = conn.private[:raw_body] || ""

    signature =
      Enum.find_value(conn.req_headers, fn {k, v} ->
        if k == "x-hub-signature-256" do
          v
        end
      end)

    if Mewtwo.GithubApp.verify_webhook_signature(body, signature) do
      {:ok, payload} = Jason.decode(body)

      if payload["action"] == "labeled" and payload["label"]["name"] == "initial-review" do
        handle_review_label(payload)
      end

      if payload["action"] == "synchronize" and has_label?(payload) do
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

    %{
      pr_id: pr_id,
      pr_number: pr_number,
      repo: repo,
      # Which installation delivered this event. Passing it on saves the worker
      # a lookup, and works even for an installation the app cannot list.
      installation_id: payload["installation"]["id"]
    }
    |> ReviewWorker.new()
    |> Oban.insert!()
  end

  defp has_label?(payload) do
    labels = payload["pull_request"]["labels"] || []
    Enum.any?(labels, fn label -> label["name"] == "initial-review" end)
  end
end
