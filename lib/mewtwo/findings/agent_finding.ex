defmodule Mewtwo.Findings.AgentFinding do
  @doc """
  Represents a single finding from an agent review

  Fields:
    - file: relative path to changed file
    - line: line number in file (1-indexed)
    - severity: high | medium | low
    - confidence: high | medium | low
    - category: bugs | perf | security | architecture | readability | etc
    - message: short description (1 line)
    - reasoning: detailed explanation of the finding
    - agent_name: which agent found it (optional)
    - sources: distinct sources that reported it, e.g. ["bugs", "gitleaks"].
      Populated by the judge's deduplicator; `length(sources)` is the
      "confirmed by N sources" count.
  """

  defstruct [
    :file,
    :line,
    :severity,
    :confidence,
    :category,
    :message,
    :reasoning,
    agent_name: nil,
    sources: []
  ]

  @type t :: %__MODULE__{
    file: String.t(),
    line: integer(),
    severity: :high | :medium | :low,
    confidence: :high | :medium | :low,
    category: String.t(),
    message: String.t(),
    reasoning: String.t(),
    agent_name: String.t() | nil,
    sources: [String.t()]
  }

  @doc "Validate severity is one of allowed values"
  def validate_severity(severity) when severity in [:high, :medium, :low], do: :ok
  def validate_severity(_), do: {:error, "severity must be :high, :medium, or :low"}

  @doc "Validate confidence is one of allowed values"
  def validate_confidence(confidence) when confidence in [:high, :medium, :low], do: :ok
  def validate_confidence(_), do: {:error, "confidence must be :high, :medium, or :low"}

  @doc """
  Create and validate a finding

  Returns: {:ok, %AgentFinding{}} or {:error, message}
  """
  def new(file, line, severity, confidence, category, message, reasoning, opts \\ []) do
    with :ok <- validate_file(file),
         :ok <- validate_line(line),
         :ok <- validate_severity(severity),
         :ok <- validate_confidence(confidence) do
      agent_name = Keyword.get(opts, :agent_name, nil)

      {:ok,
       %__MODULE__{
         file: file,
         line: line,
         severity: severity,
         confidence: confidence,
         category: category,
         message: message,
         reasoning: reasoning,
         agent_name: agent_name,
         sources: Keyword.get(opts, :sources, [])
       }}
    else
      error -> error
    end
  end

  @doc """
  How many distinct sources reported this finding

  A finding surviving deduplication with a count above 1 was reported by
  more than one agent, or by an agent and a tool.
  """
  def source_count(%__MODULE__{sources: sources}), do: length(sources)

  defp validate_file(file) when is_binary(file) and byte_size(file) > 0, do: :ok
  defp validate_file(_), do: {:error, "file must be a non-empty string"}

  defp validate_line(line) when is_integer(line) and line > 0, do: :ok
  defp validate_line(_), do: {:error, "line must be a positive integer"}
end
