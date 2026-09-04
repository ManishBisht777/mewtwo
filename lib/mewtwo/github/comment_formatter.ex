defmodule Mewtwo.Github.CommentFormatter do
  @moduledoc """
  P1 — render author findings as inline pull request review comments

  Each finding becomes three lines: a headline carrying severity, category and
  the one-line message; the reasoning; and a footer with the confidence badge
  and provenance. Anything longer stops being a review comment and starts
  being an essay that authors collapse unread.

  Findings on the same `{file, line}` are merged into one comment.
  `Judge.Deduplicator` groups on `{file, line, category}`, so `bugs` and
  `security` flagging one line survive as two findings — posted separately
  they read as the bot repeating itself at the same spot.
  """

  alias Mewtwo.Findings.AgentFinding

  # Reasoning is a model's free-form explanation and can run to paragraphs.
  # Long comments get collapsed behind "..." by GitHub's UI, which hides the
  # part that tells the author what to do.
  @max_reasoning_chars 500

  @severity_badges %{high: "🔴 High", medium: "🟠 Medium", low: "⚪ Low"}
  @confidence_badges %{
    high: "✅ high confidence",
    medium: "🔸 medium confidence",
    low: "❓ low confidence"
  }

  @doc """
  Turn findings into inline comment params for GitHub's review API

  Returns a list of `%{path:, line:, side:, body:}` maps in the order the
  findings arrived, so a ranked input posts most-severe-first.

  `side: "RIGHT"` puts the comment on the post-change version of the file,
  which is what a finding's line number refers to.
  """
  def to_comments(findings) do
    findings
    |> Enum.filter(&commentable?/1)
    |> group_by_location()
    |> Enum.map(fn {{file, line}, group} ->
      %{path: file, line: line, side: "RIGHT", body: format_group(group)}
    end)
  end

  @doc """
  Format one finding as a comment body
  """
  def format(%AgentFinding{} = finding), do: format_group([finding])

  @doc """
  Format findings sharing one location as a single comment body

  Multiple findings are separated by a rule and each keeps its own headline,
  so an author can tell "two problems here" from "one problem, restated".
  """
  def format_group(findings) do
    findings
    |> Enum.map_join("\n\n---\n\n", &finding_body/1)
    |> Kernel.<>("\n\n" <> attribution())
  end

  @doc """
  A finding rendered as one markdown list item

  Used where a comment cannot be placed inline — the reviewer section of the
  summary, and the poster's fallback when GitHub rejects inline comments.
  """
  def format_line_item(%AgentFinding{} = finding) do
    "- `#{finding.file}:#{finding.line}` #{severity_badge(finding.severity)} " <>
      "**#{category(finding)}** — #{one_line(finding.message)} " <>
      "<sub>#{confidence_badge(finding.confidence)}</sub>"
  end

  @doc """
  Whether a finding can be posted as an inline comment

  A finding without a file or a positive line number has nowhere to go; it
  belongs in the summary instead of being sent to GitHub to be rejected.
  """
  def commentable?(%AgentFinding{file: file, line: line})
      when is_binary(file) and is_integer(line) and line > 0 do
    String.trim(file) != ""
  end

  def commentable?(_finding), do: false

  defp finding_body(%AgentFinding{} = finding) do
    headline =
      "**#{severity_badge(finding.severity)} · #{category(finding)}** — " <>
        one_line(finding.message)

    footer = "<sub>#{confidence_badge(finding.confidence)}#{provenance(finding)}</sub>"

    [headline, reasoning(finding), footer]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp reasoning(%AgentFinding{reasoning: reasoning}) when is_binary(reasoning) do
    reasoning
    |> String.trim()
    |> truncate(@max_reasoning_chars)
  end

  defp reasoning(_finding), do: ""

  defp provenance(%AgentFinding{sources: sources}) when length(sources) > 1 do
    " · confirmed by #{length(sources)} sources (#{Enum.join(sources, ", ")})"
  end

  defp provenance(%AgentFinding{sources: [source]}), do: " · #{source}"
  defp provenance(%AgentFinding{}), do: ""

  # Names the bot so a human reviewer can tell its comments from a colleague's.
  defp attribution, do: "<sub>🤖 posted by mewtwo</sub>"

  defp severity_badge(severity), do: Map.get(@severity_badges, severity, "⚪ Unknown")

  defp confidence_badge(confidence) do
    Map.get(@confidence_badges, confidence, "❓ unknown confidence")
  end

  defp category(%AgentFinding{category: category}) when is_binary(category) do
    trimmed = String.trim(category)

    if trimmed == "", do: "review", else: trimmed
  end

  defp category(_finding), do: "review"

  # A message that arrives with newlines would break the headline in two and
  # leave the tail rendering as body text.
  defp one_line(message) when is_binary(message) do
    message
    |> String.split(~r/\s*\R\s*/, trim: true)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp one_line(_message), do: "(no message)"

  # Slices by graphemes, not bytes: a byte cut through a multibyte character
  # yields an invalid binary that GitHub rejects as malformed JSON.
  defp truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      truncated = String.slice(text, 0, limit)

      # Cut on a word boundary so the elision does not land mid-identifier.
      case String.split(truncated, " ") do
        [single] -> single <> "…"
        words -> Enum.join(Enum.drop(words, -1), " ") <> "…"
      end
    end
  end

  defp group_by_location(findings) do
    grouped = Enum.group_by(findings, &{&1.file, &1.line})

    findings
    |> Enum.map(&{&1.file, &1.line})
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.fetch!(grouped, &1)})
  end
end
