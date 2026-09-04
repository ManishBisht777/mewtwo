defmodule Mewtwo.Repo.Migrations.CreateFindings do
  use Ecto.Migration

  def change do
    # Findings already ride along as JSON on `reviews.author_findings` — that
    # blob stays the archive of exactly what was posted. This table is the
    # queryable index: severity/confidence/source aggregates over a window are
    # a GROUP BY here and a jsonb_array_elements lateral join there.
    create table(:findings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :review_id, references(:reviews, type: :binary_id, on_delete: :delete_all), null: false

      # Which side of the judge's split this landed on.
      add :audience, :string, null: false

      # :text, not :string — a path or a message longer than 255 bytes should
      # not fail the insert that records a finished review.
      add :file, :text
      add :line, :integer
      add :severity, :string
      add :confidence, :string
      add :category, :string

      # agent | gitleaks | both — derived from `sources`. "both" is the tool
      # agreement that earns :high confidence.
      add :source, :string
      add :agent_name, :string
      add :message, :text
      add :reasoning, :text

      # Findings are immutable once the review completes.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:findings, [:review_id])
    create index(:findings, [:inserted_at])
    create index(:findings, [:severity])
    create index(:findings, [:source])
  end
end
