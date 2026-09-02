defmodule Mewtwo.Agents.AgentPrompts do
  @doc "Load system prompt shared by all agents"
  def system_prompt do
    read_prompt("system_prompt.md")
  end

  @doc """
  Get agent-specific prompt

  Agents: bugs, perf, security, architecture, readability
  """
  def agent_prompt(agent_name) when agent_name in ["bugs", "perf", "security", "architecture", "readability"] do
    read_prompt("#{agent_name}.md")
  end

  @doc """
  Get agent-specific context (project-specific guidance)

  Returns empty string if context file doesn't exist or is empty
  """
  def agent_context(agent_name) when agent_name in ["bugs", "perf", "security", "architecture", "readability"] do
    read_context("#{agent_name}_context.md")
  end

  @doc """
  Build full prompt: system + agent-specific + context

  Returns a formatted prompt string ready to send to Claude
  """
  def build_prompt(agent_name, diff, context, gitleaks_findings) do
    system = system_prompt()
    agent = agent_prompt(agent_name)
    codebase_context = agent_context(agent_name)

    context_str = format_context(context)
    gitleaks_str = format_gitleaks(gitleaks_findings)

    codebase_section =
      if String.trim(codebase_context) != "" do
        """

        ## Project-Specific Context

        #{codebase_context}
        """
      else
        ""
      end

    """
    #{system}

    ---

    ## #{String.capitalize(agent_name)} Specialization

    #{agent}#{codebase_section}

    ---

    ## Code to Review

    ### Compressed Diff
    ```diff
    #{diff}
    ```

    ### Dynamic Context
    #{context_str}

    ### Tool Findings (Gitleaks)
    #{gitleaks_str}

    ---

    ## Your Task

    Analyze the code above according to your specialization. Return findings as a JSON array.
    Only include findings you are confident about. Better to miss than to create false positives.
    """
  end

  defp read_prompt(filename) do
    path = Path.join([__DIR__, "prompts", filename])
    File.read!(path)
  end

  defp read_context(filename) do
    path = Path.join([__DIR__, "context", filename])

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp format_context(context) when is_list(context) and length(context) == 0 do
    "No additional context fetched."
  end

  defp format_context(context) when is_list(context) do
    context
    |> Enum.map(fn item ->
      type = Map.get(item, :type, "unknown")
      file = Map.get(item, :file, "unknown")
      content = Map.get(item, :content, "")

      # Limit content preview
      preview =
        content
        |> String.slice(0..150)
        |> String.replace("\n", " ")

      "- [#{type}] #{file}: #{preview}..."
    end)
    |> Enum.join("\n")
  end

  defp format_gitleaks([]) do
    "No secrets detected."
  end

  defp format_gitleaks(findings) when is_list(findings) do
    findings
    |> Enum.map(fn finding ->
      file = Map.get(finding, :file, "unknown")
      line = Map.get(finding, :line, "?")
      type = Map.get(finding, :type, "secret")

      "- #{file}:#{line} (#{type})"
    end)
    |> Enum.join("\n")
  end
end
