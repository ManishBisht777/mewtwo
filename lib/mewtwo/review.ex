defmodule Mewtwo.Review do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "reviews" do
    field :pr_id, :integer
    field :repo, :string
    field :status, :string, default: "pending"
    field :triggered_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :author_findings, :map
    field :reviewer_findings, :map

    # Current pipeline stage and when it started, for the dashboard.
    field :stage, :string
    field :stage_started_at, :utc_datetime_usec

    # Frozen at run time — see the migration.
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :calls, :integer
    field :cost_usd, :float

    field :error, :string
    field :oban_job_id, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :pr_id,
    :repo,
    :status,
    :triggered_at,
    :completed_at,
    :author_findings,
    :reviewer_findings,
    :stage,
    :stage_started_at,
    :input_tokens,
    :output_tokens,
    :calls,
    :cost_usd,
    :error,
    :oban_job_id
  ]

  def changeset(review, attrs) do
    review
    |> cast(attrs, @fields)
    |> validate_required([:pr_id, :repo, :status, :triggered_at])
  end
end
