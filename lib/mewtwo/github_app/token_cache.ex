defmodule Mewtwo.GithubApp.TokenCache do
  @moduledoc """
  Short-lived cache for GitHub App credentials

  An installation token lasts an hour and each mint is an API call, so a
  review's five-odd requests should share one. Entries carry their own expiry
  and are dropped on read once stale.

  Cache misses are never fatal: if this process is not running — a test that
  starts no supervision tree, say — reads miss and writes are dropped, and the
  caller mints a fresh token instead.
  """

  use Agent

  # Tokens are renewed this far before GitHub expires them, so a request
  # cannot be issued with a credential that dies in flight.
  @renew_margin_seconds 300

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Fetch a live value, or `:error` when absent or expired
  """
  def fetch(key) do
    if running?() do
      Agent.get(__MODULE__, &Map.get(&1, key))
      |> live()
    else
      :error
    end
  end

  @doc """
  Cache a value until `expires_at` (a unix timestamp in seconds)
  """
  def put(key, value, expires_at) do
    if running?(), do: Agent.update(__MODULE__, &Map.put(&1, key, {value, expires_at}))

    value
  end

  @doc "Drop everything — for tests, and for a credential GitHub has rejected"
  def clear do
    if running?(), do: Agent.update(__MODULE__, fn _ -> %{} end)

    :ok
  end

  @doc "Seconds before expiry at which a credential is considered stale"
  def renew_margin_seconds, do: @renew_margin_seconds

  defp live(nil), do: :error

  defp live({value, expires_at}) do
    if expires_at - @renew_margin_seconds > System.os_time(:second) do
      {:ok, value}
    else
      :error
    end
  end

  defp running?, do: Process.whereis(__MODULE__) != nil
end
