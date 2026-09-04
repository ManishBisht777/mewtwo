defmodule Mewtwo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Mewtwo.Repo,
      {Phoenix.PubSub, name: Mewtwo.PubSub},
      # Caches GitHub App installation tokens, which are per-hour and cost an
      # API call to mint.
      Mewtwo.GithubApp.TokenCache,
      # Start a worker by calling: Mewtwo.Worker.start_link(arg)
      # {Mewtwo.Worker, arg},
      # Start to serve requests, typically the last entry
      MewtwoWeb.Endpoint,
      {Oban, Application.fetch_env!(:mewtwo, Oban)}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mewtwo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MewtwoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
