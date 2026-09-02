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

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [:pr_id, :repo, :status, :triggered_at, :completed_at, :author_findings, :reviewer_findings])
    |> validate_required([:pr_id, :repo, :status, :triggered_at])
  end
end
