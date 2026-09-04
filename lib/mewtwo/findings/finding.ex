defmodule Mewtwo.Findings.Finding do
  @moduledoc """
  DB2 — one row per finding of a completed review

  `Mewtwo.Findings.AgentFinding` is the in-flight struct; this is the stored
  row. The same findings are also archived as JSON on
  `reviews.author_findings`, which is what the poster rendered; these rows
  exist so metrics can be a `GROUP BY` instead of a jsonb traversal.

  Written once, at the end of a run, by `record/3`.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Mewtwo.{Repo, Review}
  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Judge.ConfidenceScorer

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "findings" do
    belongs_to :review, Review

    field :audience, :string
    field :file, :string
    field :line, :integer
    field :severity, :string
    field :confidence, :string
    field :category, :string
    field :source, :string
    field :agent_name, :string
    field :message, :string
    field :reasoning, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Store a review's findings, replacing any already recorded for it

  One `insert_all` for the whole review rather than a changeset per finding:
  the values come from `AgentFinding` structs, which validated themselves on
  construction. The delete makes a re-run of the same review idempotent, and
  the two statements share a transaction so a crash between them cannot leave
  the review with no findings at all.
  """
  def record(review_id, author_findings, reviewer_findings) do
    rows =
      rows(review_id, author_findings, "author") ++
        rows(review_id, reviewer_findings, "reviewer")

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.delete_all(from f in __MODULE__, where: f.review_id == ^review_id)

        case rows do
          [] -> {0, nil}
          rows -> Repo.insert_all(__MODULE__, rows)
        end
      end)

    result
  end

  @doc "Findings of one review, worst first"
  def for_review(review_id) do
    Repo.all(
      from f in __MODULE__,
        where: f.review_id == ^review_id,
        order_by: [asc: f.audience, asc: f.severity, asc: f.file, asc: f.line]
    )
  end

  @doc """
  Whether an agent and a tool both reported this finding, or only one did

  Returns `"both"`, `"gitleaks"` or `"agent"`. A finding whose `sources` the
  judge never populated is an agent's, since only the deduplicator merges tool
  output in.
  """
  def source_of(%AgentFinding{sources: sources, agent_name: agent_name}) do
    {tools, agents} = Enum.split_with(sources, &ConfidenceScorer.tool_source?/1)

    cond do
      tools != [] and (agents != [] or agent_name) -> "both"
      tools != [] -> Enum.at(tools, 0)
      true -> "agent"
    end
  end

  defp rows(review_id, findings, audience) do
    now = DateTime.utc_now()

    Enum.map(findings, fn %AgentFinding{} = finding ->
      %{
        id: Ecto.UUID.generate(),
        review_id: review_id,
        audience: audience,
        file: finding.file,
        line: finding.line,
        severity: to_string(finding.severity),
        confidence: to_string(finding.confidence),
        category: finding.category,
        source: source_of(finding),
        agent_name: finding.agent_name,
        message: finding.message,
        reasoning: finding.reasoning,
        inserted_at: now
      }
    end)
  end
end
