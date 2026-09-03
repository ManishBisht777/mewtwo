defmodule Mewtwo.Workers.ReviewWorkerTest do
  use Mewtwo.DataCase, async: false

  import Ecto.Query

  alias Mewtwo.Review
  alias Mewtwo.Workers.ReviewWorker

  # The pipeline calls GitHub and Bedrock, so these tests cover the wiring and
  # the failure path rather than a successful review. The failure path is
  # driven with a deliberately bad token, which costs one GitHub request.

  @args %{"pr_id" => 123, "repo" => "owner/name", "pr_number" => 1}

  describe "a run that cannot reach GitHub" do
    setup do
      old = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", "definitely-not-a-valid-token")

      on_exit(fn ->
        if old, do: System.put_env("GITHUB_TOKEN", old), else: System.delete_env("GITHUB_TOKEN")
      end)

      %{result: ReviewWorker.perform(%Oban.Job{args: @args}), review: Repo.one!(from r in Review)}
    end

    test "still records the review it attempted", %{review: review} do
      assert review.pr_id == 123
      assert review.repo == "owner/name"
      assert review.triggered_at
    end

    test "marks the review failed rather than complete", %{review: review} do
      assert review.status == "failed"
      assert review.completed_at
    end

    test "does not fabricate findings", %{review: review} do
      assert is_nil(review.author_findings)
      assert is_nil(review.reviewer_findings)
    end

    test "cancels instead of retrying, since a 401 will not fix itself", %{result: result} do
      assert {:cancel, reason} = result
      assert reason =~ "unauthorized"
    end
  end

  describe "job configuration" do
    test "runs on the :reviews queue" do
      assert ReviewWorker.__opts__()[:queue] == :reviews
    end

    test ":reviews is a declared queue, not just a dev-only one" do
      # Declared only in dev.exs, review jobs would never be processed in prod.
      queues = Application.get_env(:mewtwo, Oban)[:queues]

      assert Keyword.has_key?(queues, :reviews)
    end

    test "builds an insertable job from webhook args" do
      changeset = ReviewWorker.new(@args)

      assert changeset.valid?
      assert changeset.changes.queue == "reviews"
      assert changeset.changes.args == @args
    end
  end
end
