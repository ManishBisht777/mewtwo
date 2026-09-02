defmodule Mewtwo.Agents.AgentPromptsTest do
  use ExUnit.Case
  alias Mewtwo.Agents.AgentPrompts

  describe "system_prompt" do
    test "loads system prompt" do
      prompt = AgentPrompts.system_prompt()

      assert is_binary(prompt)
      assert String.length(prompt) > 500
      assert String.contains?(prompt, "Code Review Agent")
      assert String.contains?(prompt, "Output Format")
      assert String.contains?(prompt, "JSON array")
    end

    test "system prompt includes validation rules" do
      prompt = AgentPrompts.system_prompt()

      assert String.contains?(prompt, "Validation Rules")
      assert String.contains?(prompt, "severity")
      assert String.contains?(prompt, "confidence")
    end

    test "system prompt explains tool agreement" do
      prompt = AgentPrompts.system_prompt()

      assert String.contains?(prompt, "Tool Agreement")
      assert String.contains?(prompt, "Gitleaks")
    end

    test "system prompt explains compression" do
      prompt = AgentPrompts.system_prompt()

      assert String.contains?(prompt, "Compression Note")
      assert String.contains?(prompt, "summarized")
    end
  end

  describe "agent_context" do
    test "returns context for all agents" do
      agents = ["bugs", "perf", "security", "architecture", "readability"]

      Enum.each(agents, fn agent ->
        context = AgentPrompts.agent_context(agent)
        assert is_binary(context)
      end)
    end

    test "rejects invalid agent name" do
      assert_raise FunctionClauseError, fn ->
        AgentPrompts.agent_context("invalid_agent")
      end
    end
  end

  describe "agent_prompt" do
    test "loads bugs agent prompt" do
      prompt = AgentPrompts.agent_prompt("bugs")

      assert is_binary(prompt)
      assert String.contains?(prompt, "Bug Finder")
      assert String.contains?(prompt, "Null")
      assert String.contains?(prompt, "crash")
    end

    test "loads perf agent prompt" do
      prompt = AgentPrompts.agent_prompt("perf")

      assert is_binary(prompt)
      assert String.contains?(prompt, "Performance")
      assert String.contains?(prompt, "N+1")
      assert String.contains?(prompt, "efficient")
    end

    test "loads security agent prompt" do
      prompt = AgentPrompts.agent_prompt("security")

      assert is_binary(prompt)
      assert String.contains?(prompt, "Security")
      assert String.contains?(prompt, "injection")
      assert String.contains?(prompt, "Gitleaks")
    end

    test "loads architecture agent prompt" do
      prompt = AgentPrompts.agent_prompt("architecture")

      assert is_binary(prompt)
      assert String.contains?(prompt, "Architecture")
      assert String.contains?(prompt, "coupling")
      assert String.contains?(prompt, "pattern")
    end

    test "loads readability agent prompt" do
      prompt = AgentPrompts.agent_prompt("readability")

      assert is_binary(prompt)
      assert String.contains?(prompt, "Readability")
      assert String.contains?(prompt, "naming")
      assert String.contains?(prompt, "understand")
    end

    test "all agent prompts include severity guide" do
      agents = ["bugs", "perf", "security", "architecture", "readability"]

      Enum.each(agents, fn agent ->
        prompt = AgentPrompts.agent_prompt(agent)
        assert String.contains?(prompt, "Severity Guide")
        assert String.contains?(prompt, "HIGH")
        assert String.contains?(prompt, "MEDIUM")
        assert String.contains?(prompt, "LOW")
      end)
    end

    test "all agent prompts include confidence guide" do
      agents = ["bugs", "perf", "security", "architecture", "readability"]

      Enum.each(agents, fn agent ->
        prompt = AgentPrompts.agent_prompt(agent)
        assert String.contains?(prompt, "Confidence Guide")
      end)
    end

    test "rejects invalid agent name" do
      assert_raise FunctionClauseError, fn ->
        AgentPrompts.agent_prompt("invalid_agent")
      end
    end
  end

  describe "build_prompt" do
    test "builds complete prompt with all sections" do
      diff = "+def new_func do\n+ true\n+end"
      context = []
      gitleaks = []

      prompt = AgentPrompts.build_prompt("bugs", diff, context, gitleaks)

      assert String.contains?(prompt, "Code Review Agent")
      assert String.contains?(prompt, "Bug Finder")
      assert String.contains?(prompt, "Compressed Diff")
      assert String.contains?(prompt, diff)
      assert String.contains?(prompt, "Dynamic Context")
      assert String.contains?(prompt, "Tool Findings")
    end

    test "includes agent specialization heading" do
      agents = ["bugs", "perf", "security", "architecture", "readability"]

      Enum.each(agents, fn agent ->
        prompt = AgentPrompts.build_prompt(agent, "diff", [], [])
        assert String.contains?(prompt, "## #{String.capitalize(agent)} Specialization")
      end)
    end

    test "handles empty context gracefully" do
      prompt = AgentPrompts.build_prompt("bugs", "diff", [], [])
      assert String.contains?(prompt, "No additional context fetched")
    end

    test "formats context items" do
      context = [
        %{type: "test", file: "test_file.exs", content: "test content here"},
        %{type: "caller", file: "caller.ex", content: "call site"}
      ]

      prompt = AgentPrompts.build_prompt("bugs", "diff", context, [])

      assert String.contains?(prompt, "[test]")
      assert String.contains?(prompt, "test_file.exs")
      assert String.contains?(prompt, "[caller]")
      assert String.contains?(prompt, "caller.ex")
    end

    test "handles empty gitleaks findings" do
      prompt = AgentPrompts.build_prompt("security", "diff", [], [])
      assert String.contains?(prompt, "No secrets detected")
    end

    test "formats gitleaks findings" do
      gitleaks = [
        %{file: "lib/config.ex", line: 10, type: "api_key"},
        %{file: "lib/secrets.ex", line: 25, type: "password"}
      ]

      prompt = AgentPrompts.build_prompt("security", "diff", [], gitleaks)

      assert String.contains?(prompt, "lib/config.ex:10")
      assert String.contains?(prompt, "api_key")
      assert String.contains?(prompt, "lib/secrets.ex:25")
      assert String.contains?(prompt, "password")
    end

    test "preserves diff code blocks" do
      diff = """
      --- a/lib/test.ex
      +++ b/lib/test.ex
      @@ -1,5 +1,5 @@
      -old line
      +new line
      """

      prompt = AgentPrompts.build_prompt("bugs", diff, [], [])

      assert String.contains?(prompt, "```diff")
      assert String.contains?(prompt, diff)
      assert String.contains?(prompt, "```")
    end

    test "prompt ends with task description" do
      prompt = AgentPrompts.build_prompt("bugs", "diff", [], [])
      assert String.contains?(prompt, "Your Task")
      assert String.contains?(prompt, "JSON array")
    end

    test "all sections present in final prompt" do
      prompt = AgentPrompts.build_prompt("bugs", "diff", [], [])

      # System sections
      assert String.contains?(prompt, "Code Review Agent")
      assert String.contains?(prompt, "Role")
      assert String.contains?(prompt, "Output Format")

      # Agent section
      assert String.contains?(prompt, "Bug Finder")

      # Code sections
      assert String.contains?(prompt, "Code to Review")
      assert String.contains?(prompt, "Compressed Diff")
      assert String.contains?(prompt, "Dynamic Context")
      assert String.contains?(prompt, "Tool Findings")

      # Task
      assert String.contains?(prompt, "Your Task")
    end

    test "includes project-specific context when available" do
      # Create a temporary context file
      context_path = "lib/mewtwo/agents/context/bugs_context.md"

      # Check if context is included in prompt
      prompt = AgentPrompts.build_prompt("bugs", "diff", [], [])

      if File.exists?(context_path) do
        content = File.read!(context_path)

        if String.trim(content) != "" do
          assert String.contains?(prompt, "Project-Specific Context")
        end
      end
    end

    test "context preview is truncated" do
      long_content = String.duplicate("x", 500)
      context = [%{type: "test", file: "test.exs", content: long_content}]

      prompt = AgentPrompts.build_prompt("bugs", "diff", context, [])

      # Content should be truncated in preview (max 150 chars + ...)
      assert String.contains?(prompt, "...")
      # Should not contain full long string
      refute String.contains?(prompt, String.duplicate("x", 200))
    end
  end
end
