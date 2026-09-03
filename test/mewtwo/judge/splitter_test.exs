defmodule Mewtwo.Judge.SplitterTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.Judge.Splitter

  defp finding(severity, confidence, file \\ "lib/a.ex") do
    {:ok, f} =
      AgentFinding.new(file, 1, severity, confidence, "bugs", "fix it", "because",
        agent_name: "bugs"
      )

    f
  end

  describe "acceptance: high/medium severity to the author" do
    test "high severity goes to the author" do
      assert {[_], []} = Splitter.split([finding(:high, :high)])
    end

    test "medium severity goes to the author" do
      assert {[_], []} = Splitter.split([finding(:medium, :medium)])
    end
  end

  describe "acceptance: low severity or uncertain to reviewers" do
    test "low severity goes to reviewers" do
      assert {[], [_]} = Splitter.split([finding(:low, :high)])
    end

    test "an uncertain finding goes to reviewers even at high severity" do
      # Telling an author to fix something we are not sure about is how a
      # review bot loses their trust.
      assert {[], [_]} = Splitter.split([finding(:high, :low)])
    end

    test "an uncertain medium finding goes to reviewers" do
      assert {[], [_]} = Splitter.split([finding(:medium, :low)])
    end
  end

  describe "split/1" do
    test "partitions a mixed set" do
      findings = [
        finding(:high, :high, "author1.ex"),
        finding(:high, :low, "reviewer1.ex"),
        finding(:medium, :medium, "author2.ex"),
        finding(:low, :high, "reviewer2.ex")
      ]

      {author, reviewer} = Splitter.split(findings)

      assert Enum.map(author, & &1.file) == ["author1.ex", "author2.ex"]
      assert Enum.map(reviewer, & &1.file) == ["reviewer1.ex", "reviewer2.ex"]
    end

    test "preserves input order within each group" do
      findings = [
        finding(:high, :high, "first.ex"),
        finding(:medium, :medium, "second.ex"),
        finding(:high, :high, "third.ex")
      ]

      assert {author, []} = Splitter.split(findings)
      assert Enum.map(author, & &1.file) == ["first.ex", "second.ex", "third.ex"]
    end

    test "returns two empty groups for no findings" do
      assert {[], []} = Splitter.split([])
    end

    test "handles an all-author and an all-reviewer set" do
      assert {[_, _], []} = Splitter.split([finding(:high, :high), finding(:medium, :high)])
      assert {[], [_, _]} = Splitter.split([finding(:low, :low), finding(:low, :high)])
    end
  end

  describe "actionable?/1" do
    test "is true only for high/medium severity that is not uncertain" do
      assert Splitter.actionable?(finding(:high, :high))
      assert Splitter.actionable?(finding(:medium, :medium))
      refute Splitter.actionable?(finding(:high, :low))
      refute Splitter.actionable?(finding(:low, :high))
    end
  end
end
