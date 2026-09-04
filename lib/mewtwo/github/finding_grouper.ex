defmodule Mewtwo.Github.FindingGrouper do
  @moduledoc """
  Collapse findings that are one recurring issue into a single pattern

  Agents review file by file, so a project-wide habit — "this module imports
  from the module it replaces", "this component takes an unused `props`" —
  comes back as one finding per file. Posted individually that is five inline
  comments saying the same sentence, which reads as a broken bot rather than
  as one piece of advice.

  A pattern needs at least #{3} findings in the same category whose messages
  are near-identical. Below that threshold the findings stay individual: two
  occurrences are a coincidence, and an inline comment on the exact line is
  worth more than a summary entry.

  Patterns cannot be inline comments — they span files, and a comment lives on
  one line — so they go in the summary with every location listed.
  """

  require Logger

  alias Mewtwo.Findings.AgentFinding

  @default_min_occurrences 3

  # Jaccard overlap of the messages' words. 0.7 groups "…to portfolio data"
  # with "…to portfolio data layer" while keeping "remove unused import" apart
  # from "remove unused variable", which share only half their words.
  @default_similarity 0.7

  # Lower is better; used to pick a pattern's representative.
  @severity_rank %{high: 0, medium: 1, low: 2}
  @confidence_rank %{high: 0, medium: 1, low: 2}
  @worst_rank 3

  @doc """
  Split findings into recurring patterns and one-off findings

  Returns `{patterns, individual}`. Each pattern is:

    * `:message`, `:category`, `:severity`, `:confidence`, `:reasoning` — from
      the pattern's representative finding
    * `:locations` — `[%{file:, line:}]` in input order
    * `:count` — how many findings it covers
    * `:files` — how many distinct files it spans
    * `:findings` — the findings themselves, for a caller that needs them

  `individual` keeps its input order, so a ranked input yields a ranked output.

  Options:

    * `:min_occurrences` — findings needed to form a pattern (default
      #{@default_min_occurrences})
    * `:similarity` — message overlap required, `0.0..1.0` (default
      #{@default_similarity})
  """
  def partition(findings, opts \\ []) do
    min_occurrences = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    similarity = Keyword.get(opts, :similarity, @default_similarity)

    {repeated, singles} =
      findings
      |> Enum.with_index()
      |> cluster(similarity)
      |> Enum.split_with(&(length(&1) >= min_occurrences))

    patterns = Enum.map(repeated, &to_pattern/1)

    # Clusters are built in input order but interleave, so the leftovers are
    # re-sorted on their original index to keep a ranked input ranked.
    individual =
      singles
      |> List.flatten()
      |> Enum.sort_by(fn {_finding, index} -> index end)
      |> Enum.map(fn {finding, _index} -> finding end)

    log_summary(patterns, individual)

    {patterns, individual}
  end

  @doc """
  Whether two findings describe the same recurring issue

  Same category, and messages overlapping by at least `similarity`.
  """
  def same_issue?(%AgentFinding{} = a, %AgentFinding{} = b, similarity) do
    category(a) == category(b) and jaccard(words(a.message), words(b.message)) >= similarity
  end

  # Leader clustering: each finding joins the first cluster whose leader it
  # matches, or starts one. One pass, deterministic, and the leader is the
  # highest-ranked message in the cluster by construction.
  defp cluster(indexed_findings, similarity) do
    Enum.reduce(indexed_findings, [], fn {finding, _index} = entry, clusters ->
      case Enum.find_index(clusters, fn [{leader, _} | _] ->
             same_issue?(leader, finding, similarity)
           end) do
        nil -> clusters ++ [[entry]]
        index -> List.update_at(clusters, index, &(&1 ++ [entry]))
      end
    end)
  end

  defp to_pattern(cluster) do
    findings = Enum.map(cluster, fn {finding, _index} -> finding end)
    representative = representative(findings)

    %{
      message: representative.message,
      category: category(representative),
      severity: representative.severity,
      confidence: representative.confidence,
      reasoning: representative.reasoning,
      locations: Enum.map(findings, &%{file: &1.file, line: &1.line}),
      count: length(findings),
      files: findings |> Enum.map(& &1.file) |> Enum.uniq() |> length(),
      findings: findings
    }
  end

  # The headline should be the phrasing most of the findings used, so the
  # pattern reads like the thing the agents kept saying. Among findings
  # sharing that phrasing, the most severe and best-explained one wins.
  defp representative(findings) do
    frequencies = Enum.frequencies_by(findings, & &1.message)

    Enum.min_by(findings, fn finding ->
      {
        -Map.get(frequencies, finding.message, 0),
        Map.get(@severity_rank, finding.severity, @worst_rank),
        Map.get(@confidence_rank, finding.confidence, @worst_rank),
        -String.length(finding.reasoning || "")
      }
    end)
  end

  defp category(%AgentFinding{category: category}) when is_binary(category) do
    String.downcase(String.trim(category))
  end

  defp category(_finding), do: "unknown"

  # Punctuation and quoting vary between otherwise identical messages —
  # "unused 'props' parameter" and "unused props parameter" are one issue.
  defp words(message) when is_binary(message) do
    message
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\-]+/u, " ")
    |> String.split(" ", trim: true)
    |> MapSet.new()
  end

  defp words(_message), do: MapSet.new()

  defp jaccard(a, b) do
    union = MapSet.union(a, b)

    if MapSet.size(union) == 0 do
      0.0
    else
      MapSet.size(MapSet.intersection(a, b)) / MapSet.size(union)
    end
  end

  defp log_summary([], _individual), do: :ok

  defp log_summary(patterns, individual) do
    Logger.info(
      "[publish] grouped #{patterns |> Enum.map(& &1.count) |> Enum.sum()} findings into " <>
        "#{length(patterns)} pattern(s), leaving #{length(individual)} individual"
    )

    Enum.each(patterns, fn pattern ->
      Logger.info(
        "[publish]   pattern x#{pattern.count} across #{pattern.files} file(s) " <>
          "[#{pattern.category}] — #{pattern.message}"
      )
    end)
  end
end
