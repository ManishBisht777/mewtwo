defmodule MewtwoWeb.WebhookController do
  use MewtwoWeb, :controller

  alias Mewtwo.Workers.ReviewWorker

  @label "initial-review"

  def github_app_webhook(conn, _params) do
    body = conn.private[:raw_body] || ""
    signature = List.first(get_req_header(conn, "x-hub-signature-256"))

    if Mewtwo.GithubApp.verify_webhook_signature(body, signature) do
      {:ok, payload} = Jason.decode(body)

      if triggers_review?(payload), do: handle_review_label(payload)

      send_resp(conn, 202, "")
    else
      send_resp(conn, 401, "Unauthorized")
    end
  end

  # The label being added, or a push to a PR that already carries it.
  defp triggers_review?(%{"action" => "labeled"} = payload),
    do: payload["label"]["name"] == @label

  defp triggers_review?(%{"action" => "synchronize"} = payload), do: has_label?(payload)
  defp triggers_review?(_payload), do: false

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
    Enum.any?(labels, &(&1["name"] == @label))
  end
end
