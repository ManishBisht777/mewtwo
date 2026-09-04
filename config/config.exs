# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mewtwo, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  # ReviewWorker runs on :reviews; without it declared here the queue only
  # exists in dev.exs and review jobs are never processed in prod.
  queues: [default: 10, reviews: 10],
  lifeline: [rescue_after: {2, :hours}],
  repo: Mewtwo.Repo

# Review sizing. diff_token_budget caps the compressed diff (files are dropped
# lowest-review-value first to fit); max_prompt_tokens is the per-agent ceiling
# checked before any model call, and must stay under the model's context window
# with room for the response.
# post_to_github posts the finished review back to the PR as one review
# comment. It needs a GITHUB_TOKEN with `pull_requests: write`; without one
# the publish stage logs the reason and the review is still stored.
config :mewtwo, :review,
  diff_token_budget: 100_000,
  max_prompt_tokens: 180_000,
  post_to_github: true

config :mewtwo, ecto_repos: [Mewtwo.Repo]

# Configure the endpoint
config :mewtwo, MewtwoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MewtwoWeb.ErrorHTML, json: MewtwoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mewtwo.PubSub,
  live_view: [signing_salt: "eVTTzTSj"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  mewtwo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  mewtwo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
