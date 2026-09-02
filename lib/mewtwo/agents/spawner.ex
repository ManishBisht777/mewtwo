defmodule Mewtwo.Agents.Spawner do
  @moduledoc """
  Spawn specialized agents in parallel and collect findings

  Each agent is a Claude model call that analyzes code for specific issues:
  - bugs: logic errors, crashes, edge cases
  - perf: performance issues, inefficiency
  - security: vulnerabilities, secrets, auth issues
  - architecture: design problems, coupling
  - readability: naming, clarity, maintainability
  """

  alias Mewtwo.Agents.AgentPrompts
  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.BedrockClient

  @doc """
  Spawn agents in parallel and collect findings

  Args:
    - agents: list of agent names ["bugs", "perf", "security", "architecture", "readability"]
    - diff: compressed diff string
    - context: dynamic context from D5 (list of maps)
    - gitleaks_findings: secrets found by Gitleaks
    - opts: keyword options
      - timeout: milliseconds (default 60000)

  Returns:
    - {:ok, findings} — all agents succeeded
    - {:ok, findings, errors: []} — some agents failed but collected partial results
  """
  def spawn_agents(agents, diff, context, gitleaks_findings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    agents
    |> Enum.map(fn agent ->
      Task.async(fn ->
        run_agent(agent, diff, context, gitleaks_findings, timeout)
      end)
    end)
    |> Task.await_many(timeout + 5_000)
    |> collect_results()
  end

  defp run_agent(agent_name, diff, context, gitleaks_findings, timeout) do
    prompt = AgentPrompts.build_prompt(agent_name, diff, context, gitleaks_findings)

    case BedrockClient.invoke(prompt, timeout) do
      {:ok, response} ->
        parse_findings(response, agent_name)

      {:error, reason} ->
        {:error, "Agent #{agent_name} failed: #{reason}"}
    end
  end

  defp parse_findings(response, agent_name) do
    case Jason.decode(response) do
      {:ok, findings} when is_list(findings) ->
        findings
        |> Enum.filter(&valid_finding?/1)
        |> Enum.map(fn f ->
          {:ok, finding} =
            AgentFinding.new(
              Map.get(f, "file"),
              Map.get(f, "line"),
              parse_severity(Map.get(f, "severity", "low")),
              parse_confidence(Map.get(f, "confidence", "low")),
              Map.get(f, "category"),
              Map.get(f, "message"),
              Map.get(f, "reasoning"),
              agent_name: agent_name
            )

          finding
        end)

      {:ok, _other} ->
        # Response was valid JSON but not a list
        []

      {:error, _reason} ->
        # Response was not valid JSON
        []
    end
  end

  defp valid_finding?(f) do
    is_map(f) &&
      Map.has_key?(f, "file") &&
      Map.has_key?(f, "line") &&
      is_binary(Map.get(f, "file")) &&
      is_integer(Map.get(f, "line"))
  end

  defp parse_severity(s) when is_binary(s) do
    case String.downcase(s) do
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      _ -> :low
    end
  end

  defp parse_severity(_), do: :low

  defp parse_confidence(c) when is_binary(c) do
    case String.downcase(c) do
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      _ -> :low
    end
  end

  defp parse_confidence(_), do: :low

  defp collect_results(results) do
    {ok_findings, errors} =
      Enum.reduce(results, {[], []}, fn
        {:error, reason}, {ok, errs} -> {ok, errs ++ [reason]}
        findings, {ok, errs} -> {ok ++ findings, errs}
      end)

    case errors do
      [] ->
        {:ok, ok_findings}

      _ ->
        {:ok, ok_findings, errors: errors}
    end
  end
end
