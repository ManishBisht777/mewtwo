defmodule Mewtwo.Judge.Deduplicator do
  @moduledoc """
  J1 — collapse findings that describe the same issue

  Agents run in parallel with overlapping remits, so two of them routinely
  flag the same line, and Gitleaks often flags a line the security agent
  already reported. Findings are grouped by `{file, line, category}`; each
  group yields one representative carrying the distinct `sources` that
  reported it, so J2 can treat agent/tool agreement as corroboration.
  """

  require Logger

  alias Mewtwo.Findings.AgentFinding

  # Gitleaks only detects secrets, so its findings are filed under the same
  # category the security agent uses — otherwise they could never group.
  @gitleaks_category "security"
  @gitleaks_source "gitleaks"

  # Lower is better; used to pick a group's representative.
  @severity_rank %{high: 0, medium: 1, low: 2}
  @confidence_rank %{high: 0, medium: 1, low: 2}
  @worst_rank 3

  @doc """
  Deduplicate agent findings against each other and against Gitleaks findings

  Returns findings in the first-appearance order of their group, each with a
  `sources` list of the distinct agents and tools that reported it —
  `AgentFinding.source_count/1` is the "confirmed by N sources" count.

  A Gitleaks finding with no matching agent finding is kept as a finding of
  its own: a secret no agent noticed still matters.
  """
  def deduplicate(agent_findings, gitleaks_findings \\ []) do
    entries =
      Enum.map(agent_findings, &agent_entry/1) ++
        Enum.flat_map(gitleaks_findings, &gitleaks_entry/1)

    deduplicated =
      entries
      |> group_preserving_order()
      |> Enum.map(&representative/1)

    log_summary(length(agent_findings), length(gitleaks_findings), deduplicated)

    deduplicated
  end

  defp agent_entry(%AgentFinding{} = finding) do
    %{
      key: group_key(finding.file, finding.line, finding.category),
      finding: finding,
      sources: sources_of(finding)
    }
  end

  # Respects sources already present, so deduplicate/2 can be re-run over its
  # own output without losing corroboration.
  defp sources_of(%AgentFinding{sources: [_ | _] = sources}), do: sources
  defp sources_of(%AgentFinding{agent_name: nil}), do: ["unknown"]
  defp sources_of(%AgentFinding{agent_name: name}), do: [name]

  defp gitleaks_entry(raw) do
    with {:ok, file} <- fetch_file(raw),
         {:ok, line} <- fetch_line(raw) do
      type = fetch(raw, :type) || "secret"
      severity = normalize_severity(fetch(raw, :severity)) || :high

      case build_gitleaks_finding(file, line, severity, type) do
        {:ok, finding} ->
          [
            %{
              key: group_key(file, line, @gitleaks_category),
              finding: finding,
              sources: [@gitleaks_source]
            }
          ]

        {:error, reason} ->
          discard(raw, reason)
      end
    else
      {:error, reason} -> discard(raw, reason)
    end
  end

  defp build_gitleaks_finding(file, line, severity, type) do
    AgentFinding.new(
      file,
      line,
      severity,
      # Placeholder: J2 assigns real confidence from tool agreement.
      :medium,
      @gitleaks_category,
      "Remove hardcoded #{type}",
      "Detected by Gitleaks as #{type}.",
      sources: [@gitleaks_source]
    )
  end

  defp discard(raw, reason) do
    Logger.warning("[judge] discarding gitleaks finding (#{reason}): #{inspect(raw)}")
    []
  end

  # Gitleaks findings arrive as plain maps that may use atom or string keys.
  defp fetch(raw, key) when is_map(raw) do
    case Map.fetch(raw, key) do
      {:ok, value} -> value
      :error -> Map.get(raw, Atom.to_string(key))
    end
  end

  defp fetch(_raw, _key), do: nil

  defp fetch_file(raw) do
    case fetch(raw, :file) do
      file when is_binary(file) ->
        if String.trim(file) == "", do: {:error, "blank file"}, else: {:ok, file}

      _ ->
        {:error, "missing file"}
    end
  end

  defp fetch_line(raw) do
    case fetch(raw, :line) do
      line when is_integer(line) and line > 0 ->
        {:ok, line}

      line when is_binary(line) ->
        case Integer.parse(String.trim(line)) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "unusable line"}
        end

      _ ->
        {:error, "missing line"}
    end
  end

  defp normalize_severity(severity) when severity in [:high, :medium, :low], do: severity

  defp normalize_severity(severity) when is_binary(severity) do
    case String.downcase(String.trim(severity)) do
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      _ -> nil
    end
  end

  defp normalize_severity(_), do: nil

  defp group_key(file, line, category) do
    {normalize_path(file), line, normalize_category(category)}
  end

  # "./lib/a.ex" and "lib/a.ex" are the same file.
  defp normalize_path(file) when is_binary(file) do
    file |> String.trim() |> String.replace_prefix("./", "")
  end

  defp normalize_path(file), do: file

  defp normalize_category(nil), do: "unknown"

  defp normalize_category(category) when is_binary(category) do
    case String.downcase(String.trim(category)) do
      "" -> "unknown"
      normalized -> normalized
    end
  end

  defp normalize_category(category), do: to_string(category)

  defp group_preserving_order(entries) do
    grouped = Enum.group_by(entries, & &1.key)

    entries
    |> Enum.map(& &1.key)
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(grouped, &1))
  end

  defp representative(group) do
    sources = group |> Enum.flat_map(& &1.sources) |> Enum.uniq()

    group
    |> Enum.map(& &1.finding)
    |> Enum.min_by(&representative_rank/1)
    |> Map.put(:sources, sources)
  end

  # Most severe wins, then most confident, then the better-explained one.
  defp representative_rank(%AgentFinding{} = finding) do
    {
      Map.get(@severity_rank, finding.severity, @worst_rank),
      Map.get(@confidence_rank, finding.confidence, @worst_rank),
      -String.length(finding.reasoning || "")
    }
  end

  defp log_summary(agent_count, gitleaks_count, deduplicated) do
    input = agent_count + gitleaks_count
    confirmed = Enum.count(deduplicated, &(AgentFinding.source_count(&1) > 1))

    Logger.info(
      "[judge] dedup: #{input} findings (#{agent_count} agent + #{gitleaks_count} gitleaks) " <>
        "-> #{length(deduplicated)} unique, #{input - length(deduplicated)} collapsed, " <>
        "#{confirmed} confirmed by multiple sources"
    )
  end
end
