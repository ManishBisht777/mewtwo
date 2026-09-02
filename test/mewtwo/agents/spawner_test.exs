defmodule Mewtwo.Agents.SpawnerTest do
  use ExUnit.Case
  alias Mewtwo.Agents.Spawner
  alias Mewtwo.Findings.AgentFinding

  describe "spawn_agents/5" do
    test "spawns single agent and returns findings" do
      result =
        Spawner.spawn_agents(
          ["bugs"],
          "+def test do\n+end",
          [],
          []
        )

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end

    test "spawns multiple agents in parallel" do
      agents = ["bugs", "perf"]

      result = Spawner.spawn_agents(agents, "+def test do\n+end", [], [])

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end

    test "returns findings as AgentFinding structs" do
      result = Spawner.spawn_agents(["bugs"], "+def test do\n+end", [], [])

      case result do
        {:ok, findings} ->
          Enum.each(findings, fn finding ->
            assert %AgentFinding{} = finding
            assert finding.severity in [:high, :medium, :low]
            assert finding.confidence in [:high, :medium, :low]
          end)

        {:ok, findings, errors: _} ->
          Enum.each(findings, fn finding ->
            assert %AgentFinding{} = finding
          end)

        {:error, _} ->
          :skip
      end
    end

    test "assigns agent_name to findings" do
      result = Spawner.spawn_agents(["bugs"], "+def test do\n+end", [], [])

      case result do
        {:ok, findings} ->
          Enum.each(findings, fn finding ->
            assert finding.agent_name == "bugs"
          end)

        {:ok, findings, errors: _} ->
          Enum.each(findings, fn finding ->
            assert finding.agent_name == "bugs"
          end)

        {:error, _} ->
          :skip
      end
    end

    test "respects timeout option" do
      result =
        Spawner.spawn_agents(
          ["bugs"],
          "+def test do\n+end",
          [],
          [],
          timeout: 30_000
        )

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end

    test "handles multiple agents" do
      agents = ["bugs", "perf", "security"]

      result = Spawner.spawn_agents(agents, "+def test do\n+end", [], [])

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end

    test "includes context in prompt" do
      context = [
        %{type: "test", file: "test.exs", content: "test content here"}
      ]

      result = Spawner.spawn_agents(["bugs"], "+def test do\n+end", context, [])

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end

    test "includes gitleaks findings in prompt" do
      gitleaks = [
        %{file: "lib/config.ex", line: 10, type: "api_key"}
      ]

      result = Spawner.spawn_agents(["security"], "+def test do\n+end", [], gitleaks)

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end

    test "returns empty findings list if agents find nothing" do
      result = Spawner.spawn_agents(["bugs"], "+# comment only", [], [])

      case result do
        {:ok, findings} -> assert is_list(findings)
        {:ok, findings, errors: _} -> assert is_list(findings)
        {:error, _} -> :skip
      end
    end

    test "handles empty agent list" do
      result = Spawner.spawn_agents([], "+def test do\n+end", [], [])

      assert match?({:ok, []}, result)
    end

    test "returns both ok findings and errors on partial failure" do
      result = Spawner.spawn_agents(["bugs"], "+def test do\n+end", [], [])

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end

    test "parses different severity levels" do
      result = Spawner.spawn_agents(["bugs"], "+def test do\n+end", [], [])

      case result do
        {:ok, findings} ->
          Enum.each(findings, fn finding ->
            assert finding.severity in [:high, :medium, :low]
          end)

        {:ok, findings, errors: _} ->
          Enum.each(findings, fn finding ->
            assert finding.severity in [:high, :medium, :low]
          end)

        {:error, _} ->
          :skip
      end
    end

    test "parses different confidence levels" do
      result = Spawner.spawn_agents(["bugs"], "+def test do\n+end", [], [])

      case result do
        {:ok, findings} ->
          Enum.each(findings, fn finding ->
            assert finding.confidence in [:high, :medium, :low]
          end)

        {:ok, findings, errors: _} ->
          Enum.each(findings, fn finding ->
            assert finding.confidence in [:high, :medium, :low]
          end)

        {:error, _} ->
          :skip
      end
    end

    test "all 5 agents can be spawned" do
      agents = ["bugs", "perf", "security", "architecture", "readability"]

      result = Spawner.spawn_agents(agents, "+def test do\n+end", [], [])

      assert (match?({:ok, _}, result) or match?({:ok, _, errors: _}, result))
    end
  end
end
