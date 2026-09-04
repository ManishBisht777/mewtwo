defmodule MewtwoWeb.Router do
  use MewtwoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MewtwoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook do
    plug :accepts, ["json"]
  end

  # The app is deployed publicly to receive GitHub App webhooks, and the
  # dashboard exposes repo names, findings and spend. No session, no user
  # table — one shared credential is the right size for an admin page.
  pipeline :admin do
    plug :dashboard_auth
  end

  scope "/", MewtwoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", MewtwoWeb do
    pipe_through [:browser, :admin]

    live "/dashboard", DashboardLive
  end

  # Other scopes may use custom stacks.
  scope "/api", MewtwoWeb do
    pipe_through :webhook
    post "/github-app/webhook", WebhookController, :github_app_webhook
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:mewtwo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MewtwoWeb.Telemetry
    end
  end

  # Read per-request, not via compile_env (which would bake the password into
  # the release at build time) and not via runtime.exs either: :dotenv loads
  # `.env` at application start, which is *after* runtime.exs is evaluated, so
  # config read there cannot see `.env` at all. Fails closed — an
  # unconfigured dashboard on a public host is worse than an unreachable one.
  defp dashboard_auth(conn, _opts) do
    username = System.get_env("DASHBOARD_USER")
    password = System.get_env("DASHBOARD_PASSWORD")

    if is_binary(username) and is_binary(password) and username != "" and password != "" do
      Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    else
      conn
      |> send_resp(
        503,
        "dashboard auth is not configured: set DASHBOARD_USER and DASHBOARD_PASSWORD"
      )
      |> halt()
    end
  end
end
