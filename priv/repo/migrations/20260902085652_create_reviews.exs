defmodule Mewtwo.Repo.Migrations.CreateReviews do
  use Ecto.Migration

  def change do
    create table(:reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pr_id, :bigint
      add :repo, :string
      add :status, :string
      add :triggered_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :author_findings, :map
      add :reviewer_findings, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:reviews, [:pr_id, :repo])
    create index(:reviews, [:status])
  end
end
