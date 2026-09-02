defmodule Mewtwo.Workers.ReviewWorker do
  use Oban.Worker, queue: :reviews, max_attempts: 3

  alias Mewtwo.Review
  alias Mewtwo.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    pr_id = args["pr_id"]
    repo = args["repo"]
    pr_number = args["pr_number"]

    # Create review record
    review =
      %Review{
        pr_id: pr_id,
        repo: repo,
        status: "pending",
        triggered_at: DateTime.utc_now()
      }
      |> Repo.insert!()

    IO.puts("Review started for PR ##{pr_number} in #{repo} (ID: #{review.id})")

    # TODO: Fetch PR context
    # TODO: Run agents in parallel
    # TODO: Call judge coordinator
    # TODO: Post to GitHub

    # Mark as complete
    review
    |> Review.changeset(%{status: "complete", completed_at: DateTime.utc_now()})
    |> Repo.update!()

    :ok
  end
end
