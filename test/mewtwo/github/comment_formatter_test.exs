defmodule Mewtwo.Github.CommentFormatterTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Github.CommentFormatter

  defp finding(opts) do
    {:ok, f} =
      AgentFinding.new(
        Keyword.get(opts, :file, "lib/a.ex"),
        Keyword.get(opts, :line, 10),
        Keyword.get(opts, :severity, :medium),
        Keyword.get(opts, :confidence, :medium),
        Keyword.get(opts, :category, "bugs"),
        Keyword.get(opts, :message, "handles nil badly"),
        Keyword.get(opts, :reasoning, "because the caller can pass nil"),
        agent_name: Keyword.get(opts, :agent_name, "bugs"),
        sources: Keyword.get(opts, :sources, ["bugs"])
      )

    f
  end

  describe "acceptance: comments ready to post" do
    test "renders each finding with file, line, severity, message and confidence" do
      comments =
        CommentFormatter.to_comments([
          finding(file: "lib/pay.ex", line: 42, severity: :high, message: "unchecked division")
        ])

      assert [%{path: "lib/pay.ex", line: 42, side: "RIGHT", body: body}] = comments

      assert body =~ "High"
      assert body =~ "bugs"
      assert body =~ "unchecked division"
      assert body =~ "medium confidence"
    end

    test "stays short enough to read without expanding" do
      body =
        CommentFormatter.format(
          finding(message: "off-by-one in the loop bound", reasoning: "index runs to n, not n-1")
        )

      assert length(String.split(body, "\n\n")) <= 4
    end

    test "keeps findings in the order given, so a ranked list posts worst-first" do
      comments =
        CommentFormatter.to_comments([
          finding(file: "lib/a.ex", line: 1, severity: :high),
          finding(file: "lib/b.ex", line: 2, severity: :low)
        ])

      assert Enum.map(comments, & &1.path) == ["lib/a.ex", "lib/b.ex"]
    end
  end

  describe "provenance" do
    test "reports the corroborating sources when more than one agrees" do
      body = CommentFormatter.format(finding(sources: ["security", "gitleaks"]))

      assert body =~ "confirmed by 2 sources"
      assert body =~ "security, gitleaks"
    end

    test "names the single source when only one reported it" do
      body = CommentFormatter.format(finding(sources: ["perf"]))

      refute body =~ "confirmed by"
      assert body =~ "perf"
    end

    test "attributes the comment to the bot, so it is not mistaken for a colleague" do
      assert CommentFormatter.format(finding([])) =~ "mewtwo"
    end
  end

  describe "one comment per location" do
    test "merges findings on the same file and line" do
      comments =
        CommentFormatter.to_comments([
          finding(line: 7, category: "bugs", message: "nil crash"),
          finding(line: 7, category: "security", message: "unvalidated input")
        ])

      # The deduplicator groups on {file, line, category}, so two categories on
      # one line survive as two findings — posted separately they read as the
      # bot repeating itself.
      assert [%{line: 7, body: body}] = comments
      assert body =~ "nil crash"
      assert body =~ "unvalidated input"
    end

    test "keeps different lines in the same file apart" do
      comments =
        CommentFormatter.to_comments([finding(line: 7), finding(line: 9)])

      assert Enum.map(comments, & &1.line) == [7, 9]
    end
  end

  describe "input that cannot be posted inline" do
    test "drops findings without a usable line" do
      assert CommentFormatter.to_comments([%AgentFinding{file: "lib/a.ex", line: nil}]) == []
      assert CommentFormatter.to_comments([%AgentFinding{file: "lib/a.ex", line: 0}]) == []
      assert CommentFormatter.to_comments([%AgentFinding{file: "  ", line: 3}]) == []
    end

    test "reports commentability so callers can list the rest in the summary" do
      refute CommentFormatter.commentable?(%AgentFinding{file: nil, line: 3})
      assert CommentFormatter.commentable?(finding([]))
    end

    test "renders an unplaceable finding as a one-line item" do
      item =
        CommentFormatter.format_line_item(finding(file: "lib/a.ex", line: 3, severity: :high))

      assert item =~ "lib/a.ex:3"
      assert item =~ "High"
      refute item =~ "\n"
    end

    test "returns no comments for no findings" do
      assert CommentFormatter.to_comments([]) == []
    end
  end

  describe "hostile model output" do
    test "flattens a multi-line message so the headline survives" do
      body = CommentFormatter.format(finding(message: "first line\nsecond line"))

      [headline | _] = String.split(body, "\n\n")

      assert headline =~ "first line second line"
    end

    test "truncates reasoning that runs to paragraphs" do
      body = CommentFormatter.format(finding(reasoning: String.duplicate("word ", 500)))

      assert String.length(body) < 900
      assert body =~ "…"
    end

    test "truncates on a character boundary, not a byte boundary" do
      # A byte-wise cut through a multibyte character yields an invalid binary
      # that GitHub rejects as malformed JSON.
      body = CommentFormatter.format(finding(reasoning: String.duplicate("é", 800)))

      assert String.valid?(body)
    end

    test "tolerates a missing message, category and reasoning" do
      body =
        CommentFormatter.format(%AgentFinding{
          file: "lib/a.ex",
          line: 1,
          severity: :low,
          confidence: :low,
          category: nil,
          message: nil,
          reasoning: nil
        })

      assert body =~ "(no message)"
      assert body =~ "review"
    end

    test "labels an unrecognised severity rather than crashing" do
      body = CommentFormatter.format(%AgentFinding{file: "a.ex", line: 1, severity: :critical})

      assert body =~ "Unknown"
    end
  end
end
