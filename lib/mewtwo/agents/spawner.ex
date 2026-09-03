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

  require Logger

  require Logger

  alias Mewtwo.Agents.AgentPrompts
  alias Mewtwo.Findings.AgentFinding
  alias Mewtwo.BedrockClient
  alias Mewtwo.Cost
  alias Mewtwo.TokenCounter

  @doc """
  Spawn agents in parallel and collect findings

  Args:
    - agents: list of agent names ["bugs", "perf", "security", "architecture", "readability"]
    - diff: compressed diff string
    - context: dynamic context from D5 (list of maps)
    - gitleaks_findings: secrets found by Gitleaks
    - opts: keyword options
      - timeout: milliseconds (default 60000)

  Returns `{:ok, findings, meta}` where meta is:

    - `:usage` — token usage summed across every agent call
    - `:errors` — one message per agent that failed (empty when all succeeded)
    - `:per_agent` — `%{agent_name => %{findings: n, usage: usage}}`
  """
  def spawn_agents(agents, diff, context, gitleaks_findings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    started = System.monotonic_time(:millisecond)

    Logger.info(
      "[agents] spawning #{length(agents)}: #{Enum.join(agents, ", ")} " <>
        "(#{length(context)} context items, #{length(gitleaks_findings)} tool findings, " <>
        "timeout #{timeout}ms)"
    )

    results =
      agents
      |> Enum.map(fn agent ->
        Task.async(fn ->
          run_agent(agent, diff, context, gitleaks_findings, timeout)
        end)
      end)
      |> Task.await_many(timeout + 5_000)

    collect_results(results, agents, System.monotonic_time(:millisecond) - started)
  end

  defp run_agent(agent_name, diff, context, gitleaks_findings, timeout) do
    started = System.monotonic_time(:millisecond)
    prompt = AgentPrompts.build_prompt(agent_name, diff, context, gitleaks_findings)
    prompt_tokens = TokenCounter.count_tokens(prompt, :code)

    Logger.info(
      "[agent #{agent_name}] start: #{byte_size(prompt)} byte prompt, ~#{prompt_tokens} tokens"
    )

    if prompt_tokens > max_prompt_tokens() do
      # Sending it anyway buys one 400 per agent and no review.
      reason =
        "prompt is ~#{prompt_tokens} tokens, over the #{max_prompt_tokens()} limit " <>
          "(reduce the compression token budget)"

      Logger.error("[agent #{agent_name}] skipped without calling the model: #{reason}")

      {:error, agent_name, "Agent #{agent_name} skipped: #{reason}"}
    else
      invoke_agent(agent_name, prompt, timeout, started)
    end
  end

  defp max_prompt_tokens do
    :mewtwo
    |> Application.get_env(:review, [])
    |> Keyword.get(:max_prompt_tokens, 180_000)
  end

  defp invoke_agent(agent_name, prompt, timeout, started) do
    case BedrockClient.invoke(prompt, timeout) do
      {:ok, response, usage} ->
        elapsed = System.monotonic_time(:millisecond) - started
        findings = parse_findings(response, agent_name)

        log_agent_output(agent_name, findings, usage, response, elapsed)

        {:ok, agent_name, findings, usage}

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - started
        Logger.error("[agent #{agent_name}] failed after #{elapsed}ms: #{reason}")
        {:error, agent_name, "Agent #{agent_name} failed: #{reason}"}
    end
  end

  @doc """
  Extract and parse findings from a raw model response

  Models routinely wrap the JSON array in a ```json fence or a sentence of
  preamble, so a bare `Jason.decode/1` on the whole response silently drops
  every finding. Candidates are tried in order: the trimmed response, any
  fenced code blocks, then the first balanced `[...]` / `{...}` span.

  Returns a list of `AgentFinding` structs. Logs a warning when a non-empty
  response yields nothing parseable, so a parse failure stays distinguishable
  from a genuine "no findings" result.
  """
  def parse_findings(response, agent_name) when is_binary(response) do
    case extract_findings(response) do
      {:ok, raw_findings} ->
        raw_findings
        |> Enum.map(&build_finding(&1, agent_name))
        |> Enum.reject(&is_nil/1)

      :error ->
        log_unparseable(response, agent_name)
        []
    end
  end

  defp log_unparseable(response, agent_name) do
    if String.trim(response) != "" do
      Logger.warning(
        "Agent #{agent_name}: no JSON findings found in #{byte_size(response)}-byte " <>
          "response: #{String.slice(response, 0..200)}"
      )
    end
  end

  defp extract_findings(response) do
    response
    |> json_candidates()
    |> Enum.find_value(:error, fn candidate ->
      with {:ok, decoded} <- Jason.decode(candidate),
           {:ok, findings} <- normalize(decoded) do
        {:ok, findings}
      else
        _ -> nil
      end
    end)
  end

  defp json_candidates(response) do
    trimmed = String.trim(response)

    [trimmed] ++ fenced_blocks(trimmed) ++ balanced_spans(trimmed)
  end

  @fence_pattern ~r/```[ \t]*(?:json)?[ \t]*\r?\n?(.*?)```/is

  defp fenced_blocks(text) do
    @fence_pattern
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [block] -> String.trim(block) end)
  end

  # An array is tried before an object so that `[{...}]` is read as a list of
  # findings rather than as the single object it starts with.
  defp balanced_spans(text) do
    Enum.flat_map([{?[, ?]}, {?{, ?}}], fn {open, close} ->
      case balanced_span(text, open, close) do
        nil -> []
        span -> [span]
      end
    end)
  end

  defp balanced_span(text, open, close) do
    chars = String.to_charlist(text)

    case Enum.find_index(chars, &(&1 == open)) do
      nil -> nil
      start -> scan_span(Enum.drop(chars, start), open, close, 0, false, false, [])
    end
  end

  # Walks the charlist tracking brace depth, string state and escapes, so that
  # a bracket inside a JSON string literal does not end the span early.
  defp scan_span([], _open, _close, _depth, _in_str, _esc, _acc), do: nil

  defp scan_span([c | rest], open, close, depth, in_str, esc, acc) do
    acc = [c | acc]
    keep = &scan_span(rest, open, close, &1, &2, &3, acc)

    cond do
      esc -> keep.(depth, in_str, false)
      in_str and c == ?\\ -> keep.(depth, in_str, true)
      c == ?" -> keep.(depth, not in_str, false)
      in_str -> keep.(depth, in_str, false)
      c == open -> keep.(depth + 1, in_str, false)
      c == close and depth == 1 -> acc |> Enum.reverse() |> List.to_string()
      c == close -> keep.(depth - 1, in_str, false)
      true -> keep.(depth, in_str, false)
    end
  end

  defp normalize(decoded) when is_list(decoded), do: {:ok, decoded}
  defp normalize(%{"findings" => findings}) when is_list(findings), do: {:ok, findings}
  defp normalize(%{"file" => _} = finding), do: {:ok, [finding]}
  defp normalize(_), do: :error

  # Returns nil rather than raising when a finding fails validation: a single
  # bad entry must not take down the agent (and with it every other agent
  # awaited by Task.await_many/2).
  defp build_finding(raw, agent_name) when is_map(raw) do
    with {:ok, line} <- coerce_line(Map.get(raw, "line")),
         {:ok, finding} <-
           AgentFinding.new(
             Map.get(raw, "file"),
             line,
             parse_severity(Map.get(raw, "severity", "low")),
             parse_confidence(Map.get(raw, "confidence", "low")),
             Map.get(raw, "category"),
             Map.get(raw, "message"),
             Map.get(raw, "reasoning"),
             agent_name: agent_name
           ) do
      finding
    else
      {:error, reason} ->
        Logger.debug("Agent #{agent_name}: discarding finding (#{reason}): #{inspect(raw)}")
        nil
    end
  end

  defp build_finding(_raw, _agent_name), do: nil

  # Models sometimes emit the line number as a string.
  defp coerce_line(line) when is_integer(line), do: {:ok, line}

  defp coerce_line(line) when is_binary(line) do
    case Integer.parse(String.trim(line)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "line must be a positive integer"}
    end
  end

  defp coerce_line(_), do: {:error, "line must be a positive integer"}

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

  defp log_agent_output(agent_name, findings, usage, response, elapsed_ms) do
    Logger.info(
      "[agent #{agent_name}] ok in #{elapsed_ms}ms: #{byte_size(response)} byte response, " <>
        "#{Cost.describe(usage)} -> #{length(findings)} findings#{severity_breakdown(findings)}"
    )

    if findings == [] do
      Logger.info("[agent #{agent_name}] reported no findings")
    else
      Enum.each(findings, fn finding ->
        Logger.info(
          "[agent #{agent_name}]   #{finding.severity}/#{finding.confidence} " <>
            "#{finding.file}:#{finding.line} [#{finding.category}] #{finding.message}"
        )

        if finding.reasoning do
          Logger.debug("[agent #{agent_name}]     #{finding.reasoning}")
        end
      end)
    end
  end

  defp severity_breakdown([]), do: ""

  defp severity_breakdown(findings) do
    breakdown =
      findings
      |> Enum.frequencies_by(& &1.severity)
      |> Enum.map_join(" ", fn {severity, count} -> "#{severity}=#{count}" end)

    " (#{breakdown})"
  end

  defp collect_results(results, agents, elapsed_ms) do
    findings =
      Enum.flat_map(results, fn
        {:ok, _agent, agent_findings, _usage} -> agent_findings
        {:error, _agent, _reason} -> []
      end)

    errors = for {:error, _agent, reason} <- results, do: reason

    usage =
      results
      |> Enum.flat_map(fn
        {:ok, _agent, _findings, agent_usage} -> [agent_usage]
        {:error, _agent, _reason} -> []
      end)
      |> Cost.total()

    per_agent =
      Map.new(results, fn
        {:ok, agent, agent_findings, agent_usage} ->
          {agent, %{findings: length(agent_findings), usage: agent_usage}}

        {:error, agent, _reason} ->
          {agent, %{findings: 0, usage: Cost.zero()}}
      end)

    Logger.info(
      "[agents] done in #{elapsed_ms}ms: #{length(findings)} findings from " <>
        "#{length(agents) - length(errors)}/#{length(agents)} agents, #{Cost.describe(usage)}"
    )

    Enum.each(errors, &Logger.error("[agents] #{&1}"))

    {:ok, findings, %{usage: usage, errors: errors, per_agent: per_agent}}
  end
end
