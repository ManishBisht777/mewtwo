defmodule Mewtwo.Repo.Migrations.AddDashboardFields do
  use Ecto.Migration

  def change do
    alter table(:reviews) do
      # Current pipeline stage, written at each boundary by ReviewWorker.
      add :stage, :string
      add :stage_started_at, :utc_datetime_usec

      # Cost is frozen at run time: rates can change, so recomputing on read
      # would rewrite history. cost_usd is NULL when BEDROCK_*_USD_PER_MTOK
      # were unset for that run.
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :calls, :integer
      add :cost_usd, :float

      add :error, :text

      # Oban is the source of truth for liveness; the review row for what the
      # run was doing. Without this a restarted node leaves rows that render
      # as "running" forever.
      add :oban_job_id, :bigint
    end

    create index(:reviews, [:triggered_at])
  end
end
