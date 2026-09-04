defmodule Mewtwo.Github.SummaryFormatter do
  @moduledoc """
  P2 — render the one summary comment that heads a review

  The inline comments say what to fix. This says what the run did: how many
  findings there are and how severe, what corroborated them, how much of the
  diff the agents actually saw, and what it cost.

  It also carries the findings that cannot be inline comments: recurring
  patterns spanning several files (see `Mewtwo.Github.FindingGrouper`), and
  findings whose line GitHub would reject. Everything else is left out, since
  an inline comment already says it and repeating it here shows every finding
  on the PR twice.

  Every stat is optional. The worker only has compression and context numbers
  when those stages ran, so a missing key omits its line rather than printing
  a zero that reads as a real measurement.
  """

  alias Mewtwo.Cost
  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Github.{CommentFormatter, FindingGrouper}

  @severities [:high, :medium, :low]
  @severity_badges %{high: "🔴 High", medium: "🟠 Medium", low: "⚪ Low"}

  # Reviewer findings are context, not a task list. Past a dozen the summary
  # stops being skimmable, and they are all on the review record anyway.
  @max_reviewer_items 12

  # Locations listed per pattern before it collapses to a count.
  @max_pattern_locations 10

  @doc """
  Build the summary comment body

  `metadata` is `Judge.judge/3`'s metadata map, optionally extended with:

    * `:usage` — a `Mewtwo.Cost` usage map
    * `:compression` — `Mewtwo.Compression.compress/2`'s metadata
    * `:context` — `Mewtwo.DynamicContext.fetch/3`'s result, or the counts
      alone as `%{fetched: n, skipped: n, tokens_used: n}`, or `nil` when the
      stage was skipped
    * `:agents` — the agent names that ran

  Any of them may be absent.
  """
  def format(author_findings, reviewer_findings, metadata \\ %{}) do
    # Grouping is a pure function of the findings, so the poster gets the same
    # split when it decides what to comment on inline.
    {patterns, individual} = FindingGrouper.partition(author_findings)

    [
      heading(author_findings, reviewer_findings),
      severity_table(author_findings, reviewer_findings),
      patterns_section(patterns),
      author_section(individual),
      reviewer_section(reviewer_findings),
      run_details(metadata),
      footer()
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp heading([], []), do: "## 🤖 Mewtwo review\n\nNo findings. ✅"

  defp heading(author, reviewer) do
    counts =
      [
        count(length(author), "finding", "findings") <> " for you",
        if(reviewer != [], do: "#{length(reviewer)} for reviewers")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    "## 🤖 Mewtwo review\n\n**#{counts}**"
  end

  defp severity_table([], []), do: nil

  defp severity_table(author, reviewer) do
    rows =
      @severities
      |> Enum.map(fn severity ->
        {severity, count_by_severity(author, severity), count_by_severity(reviewer, severity)}
      end)
      |> Enum.reject(fn {_severity, in_author, in_reviewer} ->
        in_author == 0 and in_reviewer == 0
      end)
      |> Enum.map_join("\n", fn {severity, in_author, in_reviewer} ->
        "| #{Map.fetch!(@severity_badges, severity)} | #{in_author} | #{in_reviewer} |"
      end)

    """
    | Severity | For the author | For reviewers |
    |---|---|---|
    #{rows}
    """
    |> String.trim()
  end

  # One entry for an issue the agents reported file after file. It cannot be an
  # inline comment — it spans files, and a comment lives on one line — so the
  # locations are listed here instead of as N comments repeating one sentence.
  defp patterns_section([]), do: nil

  defp patterns_section(patterns) do
    "### Repeated across the diff\n\n" <> Enum.map_join(patterns, "\n\n", &pattern/1)
  end

  defp pattern(pattern) do
    headline =
      "**#{severity_badge(pattern.severity)} · #{pattern.category}** — #{pattern.message} " <>
        "<sub>#{pattern.count}× in #{pattern.files} #{plural(pattern.files, "file", "files")}</sub>"

    shown = Enum.take(pattern.locations, @max_pattern_locations)

    locations =
      Enum.map_join(shown, "\n", fn location ->
        "- `#{location.file}:#{location.line}`"
      end)

    overflow =
      case length(pattern.locations) - length(shown) do
        0 -> ""
        n -> "\n- …and #{n} more"
      end

    [headline, reasoning(pattern), locations <> overflow]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # The compact form, for the collapsed reviewer list: one line plus its
  # locations, rather than a paragraph per pattern.
  defp pattern_line_item(pattern) do
    shown = Enum.take(pattern.locations, @max_pattern_locations)

    locations =
      Enum.map_join(shown, ", ", fn location -> "`#{location.file}:#{location.line}`" end)

    overflow =
      case length(pattern.locations) - length(shown) do
        0 -> ""
        n -> ", and #{n} more"
      end

    "- #{severity_badge(pattern.severity)} **#{pattern.category}** — #{pattern.message} " <>
      "<sub>#{pattern.count}× in #{pattern.files} #{plural(pattern.files, "file", "files")}</sub>" <>
      "\n  - #{locations}#{overflow}"
  end

  defp reasoning(%{reasoning: reasoning}) when is_binary(reasoning), do: String.trim(reasoning)
  defp reasoning(_pattern), do: ""

  defp severity_badge(severity), do: Map.get(@severity_badges, severity, "⚪ Unknown")

  # Inline comments carry the individual author findings, so the summary only
  # lists the ones that could not be placed on a line — otherwise every
  # finding appears twice on the PR.
  defp author_section(author) do
    case Enum.reject(author, &CommentFormatter.commentable?/1) do
      [] ->
        nil

      unplaceable ->
        items = Enum.map_join(unplaceable, "\n", &CommentFormatter.format_line_item/1)

        "**#{count(length(unplaceable), "finding", "findings")} without a usable line**, " <>
          "listed here instead of inline:\n\n#{items}"
    end
  end

  defp reviewer_section([]), do: nil

  defp reviewer_section(reviewer) do
    # Reviewer findings repeat across files just as author findings do — the
    # same nit on twelve components is one entry, not twelve.
    {patterns, individual} = FindingGrouper.partition(reviewer)

    entries =
      Enum.map(patterns, &pattern_line_item/1) ++
        Enum.map(individual, &CommentFormatter.format_line_item/1)

    shown = Enum.take(entries, @max_reviewer_items)
    items = Enum.join(shown, "\n")

    overflow =
      case length(entries) - length(shown) do
        0 -> ""
        n -> "\n\n…and #{n} more on the review record."
      end

    """
    <details>
    <summary>#{count(length(reviewer), "finding", "findings")} for reviewers — context, not blocking</summary>

    #{items}#{overflow}
    </details>
    """
    |> String.trim()
  end

  defp run_details(metadata) do
    case Enum.reject(detail_lines(metadata), &is_nil/1) do
      [] ->
        nil

      lines ->
        """
        <details>
        <summary>Run details</summary>

        #{Enum.join(lines, "\n")}
        </details>
        """
        |> String.trim()
    end
  end

  defp detail_lines(metadata) do
    [
      agents_line(metadata),
      agreement_line(metadata),
      gitleaks_line(metadata),
      dedup_line(metadata),
      compression_line(metadata),
      truncation_line(metadata),
      context_line(metadata),
      usage_line(metadata)
    ]
  end

  defp agents_line(metadata) do
    case {get(metadata, :total_agents), get(metadata, :agents)} do
      {nil, nil} -> nil
      {_count, [_ | _] = agents} -> "- **Agents:** #{length(agents)} (#{Enum.join(agents, ", ")})"
      {count, _} -> "- **Agents:** #{count}"
    end
  end

  defp agreement_line(metadata) do
    case get(metadata, :tool_agreement_rate) do
      rate when is_number(rate) ->
        "- **Tool agreement:** #{percent(rate)} of findings flagged by both an agent and a tool"

      _ ->
        nil
    end
  end

  # An explicit "not available" matters: with no tool running, nothing can
  # reach high confidence, and a bare 0 looks like a clean bill of health.
  defp gitleaks_line(metadata) do
    case get(metadata, :gitleaks_findings_count) do
      nil -> nil
      0 -> "- **Gitleaks:** no findings"
      count -> "- **Gitleaks:** #{count} #{plural(count, "finding", "findings")}"
    end
  end

  defp dedup_line(metadata) do
    case get(metadata, :dedup_count) do
      count when is_integer(count) and count > 0 ->
        "- **Duplicates collapsed:** #{count}"

      _ ->
        nil
    end
  end

  defp compression_line(metadata) do
    with compression when is_map(compression) <- get(metadata, :compression),
         original when is_integer(original) <- get(compression, :original_tokens),
         compressed when is_integer(compressed) <- get(compression, :compressed_tokens),
         true <- original > 0 do
      saved = Float.round((1.0 - compressed / original) * 100, 1)

      "- **Compression:** #{number(original)} → #{number(compressed)} diff tokens " <>
        "(#{saved}% saved)"
    else
      _ -> nil
    end
  end

  # Dropped files are not reviewed at all, which is the one stat an author
  # needs in order to distrust a clean result.
  defp truncation_line(metadata) do
    with compression when is_map(compression) <- get(metadata, :compression),
         dropped when is_integer(dropped) and dropped > 0 <-
           get(compression, :truncated_sections) do
      "- ⚠️ **Not reviewed:** #{dropped} #{plural(dropped, "file", "files")} dropped to fit " <>
        "the token budget"
    else
      _ -> nil
    end
  end

  # An absent :context key means the caller did not report on the stage; an
  # explicit nil means the stage ran nowhere. Only the second is worth saying,
  # since it changes how much the findings are worth.
  defp context_line(metadata) do
    cond do
      not has_key?(metadata, :context) -> nil
      is_nil(get(metadata, :context)) -> context_skipped_line()
      true -> context_fetched_line(get(metadata, :context))
    end
  end

  defp context_skipped_line do
    "- **Context:** skipped (no checkout available), so agents saw the diff only"
  end

  defp context_fetched_line(context) when is_map(context) do
    fetched = size(get(context, :fetched_context) || get(context, :fetched))
    skipped = size(get(context, :skipped_items) || get(context, :skipped))
    tokens = get(context, :tokens_used)

    "- **Context:** #{fetched} #{plural(fetched, "item", "items")} fetched, " <>
      "#{skipped} skipped#{if tokens, do: " (#{number(tokens)} tokens)", else: ""}"
  end

  defp context_fetched_line(_context), do: nil

  defp usage_line(metadata) do
    case get(metadata, :usage) do
      %{input_tokens: _, output_tokens: _} = usage -> "- **Model usage:** #{Cost.describe(usage)}"
      _ -> nil
    end
  end

  defp footer do
    "<sub>Findings are ranked by severity, then by how much corroborated them. " <>
      "High confidence means an agent and a tool independently flagged the same issue.</sub>"
  end

  defp count_by_severity(findings, severity) do
    Enum.count(findings, fn %AgentFinding{severity: value} -> value == severity end)
  end

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{n} #{plural}"

  defp plural(1, singular, _plural), do: singular
  defp plural(_n, _singular, plural), do: plural

  defp percent(rate), do: "#{round(rate * 100)}%"

  # Metadata reaches here as atom-keyed maps from the pipeline and as
  # string-keyed maps when read back out of the reviews table.
  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_map, _key), do: nil

  defp has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp has_key?(_map, _key), do: false

  # Context arrives either as the fetched items themselves or, from a caller
  # that kept only the counts to avoid persisting whole files, as a number.
  defp size(items) when is_list(items), do: length(items)
  defp size(count) when is_integer(count), do: count
  defp size(_other), do: 0

  # 412000 -> "412,000"
  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp number(n), do: to_string(n)
end
