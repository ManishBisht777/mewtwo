defmodule Mewtwo.Repo.Migrations.CreateReviews do
  use Ecto.Migration

  def change do
    create table(:reviews) do
      add :pr_id, :integer
      add :repo, :string
      add :status, :string
      add :triggered_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :author_findings, :map
      add :reviewer_findings, :map

      timestamps(type: :utc_datetime)
    end
  end
end
