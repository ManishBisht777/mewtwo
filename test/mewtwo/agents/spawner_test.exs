defmodule Mewtwo.Agents.SpawnerTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Agents.Spawner
  alias Mewtwo.Findings.AgentFinding

  # These tests deliberately avoid spawn_agents/5 with a non-empty agent list,
  # since that makes a live (billed) Bedrock call per agent. Response parsing is
  # exercised directly through parse_findings/2.

  @finding_json """
  [
    {
      "file": "lib/module.ex",
      "line": 42,
      "severity": "high",
      "confidence": "medium",
      "category": "bugs",
      "message": "remove unused variable 'x'",
      "reasoning": "Assigned on line 40 but never read."
    }
  ]
  """

  defp parse(response), do: Spawner.parse_findings(response, "bugs")

  describe "parse_findings/2 — extraction" do
    test "parses a bare JSON array" do
      assert [%AgentFinding{} = finding] = parse(@finding_json)
      assert finding.file == "lib/module.ex"
      assert finding.line == 42
      assert finding.severity == :high
      assert finding.confidence == :medium
      assert finding.message == "remove unused variable 'x'"
    end

    test "parses a ```json fenced array" do
      assert [%AgentFinding{line: 42}] = parse("```json\n#{@finding_json}```")
    end

    test "parses an unlabelled fenced array" do
      assert [%AgentFinding{line: 42}] = parse("```\n#{@finding_json}```")
    end

    test "parses an array behind a prose preamble" do
      response = "Here are the findings I'm confident about:\n\n#{@finding_json}"

      assert [%AgentFinding{line: 42}] = parse(response)
    end

    test "parses an array wrapped in both prose and a fence" do
      response = """
      I reviewed the diff and found one issue.

      ```json
      #{@finding_json}
      ```

      Let me know if you want more detail.
      """

      assert [%AgentFinding{line: 42}] = parse(response)
    end

    test "parses an array followed by trailing prose" do
      assert [%AgentFinding{line: 42}] = parse("#{@finding_json}\n\nThat's the only issue.")
    end

    test "unwraps a top-level object keyed by findings" do
      assert [%AgentFinding{line: 42}] = parse(~s({"findings": #{@finding_json}}))
    end

    test "wraps a single bare finding object into a list" do
      response = ~s({"file": "lib/a.ex", "line": 7, "severity": "low", "confidence": "low"})

      assert [%AgentFinding{file: "lib/a.ex", line: 7}] = parse(response)
    end

    test "does not end the span on a bracket inside a string literal" do
      response = """
      Findings:
      [{"file": "lib/a.ex", "line": 3, "severity": "low", "confidence": "low",
        "message": "rename list[0] access", "reasoning": "Uses a \\"]\\" in text."}]
      """

      assert [%AgentFinding{} = finding] = parse(response)
      assert finding.message == "rename list[0] access"
      assert finding.reasoning == ~s(Uses a "]" in text.)
    end

    test "parses multiple findings and preserves order" do
      response = """
      [{"file": "a.ex", "line": 1, "severity": "high", "confidence": "high"},
       {"file": "b.ex", "line": 2, "severity": "low", "confidence": "low"}]
      """

      assert [%AgentFinding{file: "a.ex"}, %AgentFinding{file: "b.ex"}] = parse(response)
    end
  end

  describe "parse_findings/2 — empty and unparseable responses" do
    test "returns [] for an explicitly empty array" do
      assert parse("[]") == []
      assert parse("```json\n[]\n```") == []
    end

    test "returns [] for an empty response" do
      assert parse("") == []
      assert parse("   \n  ") == []
    end

    test "returns [] for prose with no JSON at all" do
      assert parse("I found no issues in this diff.") == []
    end

    test "returns [] for malformed JSON" do
      assert parse(~s([{"file": "a.ex", "line":)) == []
    end
  end

  describe "parse_findings/2 — field coercion" do
    test "coerces a stringified line number" do
      response = ~s([{"file": "a.ex", "line": "42", "severity": "low", "confidence": "low"}])

      assert [%AgentFinding{line: 42}] = parse(response)
    end

    test "defaults missing severity and confidence to :low" do
      assert [%AgentFinding{severity: :low, confidence: :low}] =
               parse(~s([{"file": "a.ex", "line": 1}]))
    end

    test "downcases severity and confidence" do
      response = ~s([{"file": "a.ex", "line": 1, "severity": "HIGH", "confidence": "Medium"}])

      assert [%AgentFinding{severity: :high, confidence: :medium}] = parse(response)
    end

    test "falls back to :low for an unrecognised severity" do
      response = ~s([{"file": "a.ex", "line": 1, "severity": "critical", "confidence": "low"}])

      assert [%AgentFinding{severity: :low}] = parse(response)
    end

    test "tags every finding with the agent name" do
      assert [%AgentFinding{agent_name: "security"}] =
               Spawner.parse_findings(~s([{"file": "a.ex", "line": 1}]), "security")
    end
  end

  describe "parse_findings/2 — invalid findings are dropped, not raised" do
    test "drops a finding with a non-positive line instead of crashing" do
      assert parse(~s([{"file": "a.ex", "line": 0}])) == []
      assert parse(~s([{"file": "a.ex", "line": -3}])) == []
    end

    test "drops a finding with an empty or missing file" do
      assert parse(~s([{"file": "", "line": 1}])) == []
      assert parse(~s([{"line": 1, "severity": "high"}])) == []
    end

    test "drops a finding with an unusable line value" do
      assert parse(~s([{"file": "a.ex", "line": "not a number"}])) == []
      assert parse(~s([{"file": "a.ex"}])) == []
    end

    test "drops non-object entries" do
      assert parse(~s(["just a string", 42, null])) == []
    end

    test "keeps valid findings alongside invalid ones" do
      response = """
      [{"file": "a.ex", "line": 0},
       {"file": "good.ex", "line": 9, "severity": "high", "confidence": "high"},
       {"file": "", "line": 5}]
      """

      assert [%AgentFinding{file: "good.ex", line: 9}] = parse(response)
    end
  end

  describe "spawn_agents/5" do
    test "returns no findings for an empty agent list without calling the model" do
      assert {:ok, [], meta} = Spawner.spawn_agents([], "+def test do\n+end", [], [])

      assert meta.errors == []
      assert meta.per_agent == %{}
      assert meta.usage == Mewtwo.Cost.zero()
    end
  end
end
