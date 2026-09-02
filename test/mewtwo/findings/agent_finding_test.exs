defmodule Mewtwo.Findings.AgentFindingTest do
  use ExUnit.Case
  alias Mewtwo.Findings.AgentFinding

  describe "struct creation" do
    test "creates valid finding" do
      result =
        AgentFinding.new(
          "lib/module.ex",
          42,
          :high,
          :medium,
          "bugs",
          "Unused variable detected",
          "Variable 'x' is assigned but never used in this scope",
          agent_name: "bug-finder"
        )

      assert {:ok, finding} = result
      assert finding.file == "lib/module.ex"
      assert finding.line == 42
      assert finding.severity == :high
      assert finding.confidence == :medium
      assert finding.category == "bugs"
      assert finding.message == "Unused variable detected"
      assert finding.agent_name == "bug-finder"
    end

    test "creates finding without agent_name" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          10,
          :high,
          :high,
          "security",
          "SQL injection risk",
          "User input not sanitized"
        )

      assert {:ok, finding} = result
      assert finding.agent_name == nil
    end

    test "all fields are present in struct" do
      {:ok, finding} =
        AgentFinding.new(
          "lib/module.ex",
          42,
          :high,
          :medium,
          "bugs",
          "Issue found",
          "This is why it's an issue"
        )

      assert Map.has_key?(finding, :file)
      assert Map.has_key?(finding, :line)
      assert Map.has_key?(finding, :severity)
      assert Map.has_key?(finding, :confidence)
      assert Map.has_key?(finding, :category)
      assert Map.has_key?(finding, :message)
      assert Map.has_key?(finding, :reasoning)
      assert Map.has_key?(finding, :agent_name)
    end
  end

  describe "severity validation" do
    test "accepts high severity" do
      assert :ok = AgentFinding.validate_severity(:high)
    end

    test "accepts medium severity" do
      assert :ok = AgentFinding.validate_severity(:medium)
    end

    test "accepts low severity" do
      assert :ok = AgentFinding.validate_severity(:low)
    end

    test "rejects invalid severity" do
      assert {:error, _} = AgentFinding.validate_severity(:critical)
      assert {:error, _} = AgentFinding.validate_severity(:unknown)
      assert {:error, _} = AgentFinding.validate_severity("high")
    end

    test "new rejects invalid severity" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          10,
          :critical,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end
  end

  describe "confidence validation" do
    test "accepts high confidence" do
      assert :ok = AgentFinding.validate_confidence(:high)
    end

    test "accepts medium confidence" do
      assert :ok = AgentFinding.validate_confidence(:medium)
    end

    test "accepts low confidence" do
      assert :ok = AgentFinding.validate_confidence(:low)
    end

    test "rejects invalid confidence" do
      assert {:error, _} = AgentFinding.validate_confidence(:certain)
      assert {:error, _} = AgentFinding.validate_confidence(:uncertain)
      assert {:error, _} = AgentFinding.validate_confidence("high")
    end

    test "new rejects invalid confidence" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          10,
          :high,
          :uncertain,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end
  end

  describe "line validation" do
    test "accepts positive integer" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          1,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:ok, _} = result
    end

    test "accepts large line numbers" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          99_999,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:ok, _} = result
    end

    test "rejects zero" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          0,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end

    test "rejects negative number" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          -5,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end

    test "rejects string line number" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          "42",
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end

    test "rejects float line number" do
      result =
        AgentFinding.new(
          "lib/test.ex",
          42.5,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end
  end

  describe "file validation" do
    test "accepts file path" do
      result =
        AgentFinding.new(
          "lib/module.ex",
          10,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:ok, _} = result
    end

    test "accepts nested file path" do
      result =
        AgentFinding.new(
          "lib/mewtwo/context/symbol_parser.ex",
          10,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:ok, _} = result
    end

    test "rejects empty file" do
      result =
        AgentFinding.new(
          "",
          10,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end

    test "rejects non-binary file" do
      result =
        AgentFinding.new(
          :lib_module,
          10,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end

    test "rejects nil file" do
      result =
        AgentFinding.new(
          nil,
          10,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end
  end

  describe "combinations" do
    test "accepts all valid severity/confidence combinations" do
      for severity <- [:high, :medium, :low],
          confidence <- [:high, :medium, :low] do
        result =
          AgentFinding.new(
            "lib/test.ex",
            10,
            severity,
            confidence,
            "test",
            "Message",
            "Reasoning"
          )

        assert {:ok, _} = result
      end
    end

    test "categories are flexible" do
      categories = [
        "bugs",
        "perf",
        "security",
        "architecture",
        "readability",
        "custom_category"
      ]

      for category <- categories do
        result =
          AgentFinding.new(
            "lib/test.ex",
            10,
            :high,
            :high,
            category,
            "Message",
            "Reasoning"
          )

        assert {:ok, finding} = result
        assert finding.category == category
      end
    end

    test "message and reasoning can be long" do
      long_message = String.duplicate("x", 1000)
      long_reasoning = String.duplicate("y", 5000)

      result =
        AgentFinding.new(
          "lib/test.ex",
          10,
          :high,
          :high,
          "bugs",
          long_message,
          long_reasoning
        )

      assert {:ok, finding} = result
      assert finding.message == long_message
      assert finding.reasoning == long_reasoning
    end
  end

  describe "error handling" do
    test "returns error tuple on validation failure" do
      result =
        AgentFinding.new(
          "",
          10,
          :high,
          :high,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, message} = result
      assert is_binary(message)
    end

    test "first validation error is returned" do
      result =
        AgentFinding.new(
          "",
          -5,
          :invalid,
          :unknown,
          "bugs",
          "Issue",
          "Reasoning"
        )

      assert {:error, _} = result
    end
  end
end
