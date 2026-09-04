defmodule Mewtwo.GithubApp do
  @moduledoc """
  The GitHub App's identity: webhook verification and acting as the app

  A review should be authored by the app, not by whoever's personal access
  token happens to be in the environment. Comments from a human account are
  indistinguishable from that human's own review, and they consume that
  person's rate limit.

  Acting as the app is two hops:

    1. **App JWT** — signed with the app's private key (RS256), valid for
       minutes. It can read app-level endpoints but cannot touch a repository.
    2. **Installation token** — minted with that JWT for one installation,
       valid for an hour. This is what actually reads a PR and posts a review.

  Configuration, read from the environment like the rest of the GitHub code:

    * `GITHUB_APP_ID` — the numeric app id
    * `GITHUB_PRIVATE_KEY_PATH` — path to the app's `.pem`, or
      `GITHUB_PRIVATE_KEY` with the PEM inline (for deploys without a file)
    * `GITHUB_WEBHOOK_SECRET` — the webhook signing secret

  With none of these set, `token_for/2` reports `:no_app` and callers fall back
  to `GITHUB_TOKEN`.
  """

  require Logger

  alias Mewtwo.GithubApp.TokenCache
  alias Mewtwo.GithubClient

  # GitHub rejects a JWT with an `exp` more than 10 minutes out. 9 leaves room
  # for clock skew without being refused.
  @jwt_lifetime_seconds 540

  # Back-dated to survive a slow clock on our side, per GitHub's guidance.
  @jwt_backdate_seconds 60

  # Fallback when GitHub's response omits expires_at. An installation token
  # lasts an hour; assuming less costs an extra mint, assuming more would use
  # a dead credential.
  @assumed_token_lifetime_seconds 3_000

  @doc """
  Verify a webhook's HMAC-SHA256 signature
  """
  def verify_webhook_signature(payload, signature) do
    secret = System.get_env("GITHUB_WEBHOOK_SECRET")

    if secret && is_binary(signature) do
      expected_signature =
        "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload), case: :lower)

      Plug.Crypto.secure_compare(signature, expected_signature)
    else
      false
    end
  end

  @doc """
  Whether an app id and private key are both configured
  """
  def configured?, do: app_id() != nil and private_key() != nil

  @doc """
  An installation token for `repo`, so requests act as the app

  Returns `{:ok, token}`, `:no_app` when the app is not configured, or
  `{:error, reason}` when GitHub refuses.

  Options:

    * `:installation_id` — skip the lookup. Webhook payloads carry
      `installation.id`, which saves a request and works even for an
      installation the app cannot list.
    * `:request_opts` — passed through to `Mewtwo.GithubClient`

  Tokens are cached until shortly before they expire, so a review's requests
  share one.
  """
  def token_for(repo, opts \\ []) do
    if configured?() do
      with {:ok, installation_id} <- resolve_installation(repo, opts) do
        installation_token(installation_id, opts)
      end
    else
      :no_app
    end
  end

  @doc """
  Mint an installation token, or return a cached live one
  """
  def installation_token(installation_id, opts \\ []) do
    case TokenCache.fetch({:installation_token, installation_id}) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        with {:ok, jwt} <- jwt() do
          request_installation_token(installation_id, jwt, opts)
        end
    end
  end

  @doc """
  Look up which installation covers `repo`

  Requires the app to be installed on the repository.
  """
  def installation_id(repo, opts \\ []) do
    case TokenCache.fetch({:installation_id, repo}) do
      {:ok, id} ->
        {:ok, id}

      :error ->
        with {:ok, jwt} <- jwt(),
             {:ok, %{"id" => id}} <-
               GithubClient.get(
                 "/repos/#{repo}/installation",
                 [token: jwt] ++ request_opts(opts)
               ) do
          Logger.info("[github_app] #{repo} is installation #{id}")

          # Which installation owns a repo effectively never changes, but an
          # app can be uninstalled, so this is cached for an hour rather than
          # for the life of the node.
          {:ok, TokenCache.put({:installation_id, repo}, id, System.os_time(:second) + 3_600)}
        else
          {:ok, body} ->
            {:error, {:unexpected_body, "no installation id in #{inspect(body, limit: 5)}"}}

          {:error, {:not_found, _}} ->
            {:error,
             {:not_installed, "the GitHub App is not installed on #{repo}, or cannot see it"}}

          error ->
            error
        end
    end
  end

  @doc """
  A short-lived JWT signed with the app's private key

  Authenticates as the app itself. Cannot read a repository — mint an
  installation token for that.
  """
  def jwt do
    with {:ok, app_id} <- fetch(app_id(), {:missing_config, "GITHUB_APP_ID is not set"}),
         {:ok, pem} <- fetch(private_key(), {:missing_config, private_key_error()}),
         {:ok, signer} <- signer(pem) do
      now = System.os_time(:second)

      claims = %{
        "iat" => now - @jwt_backdate_seconds,
        "exp" => now + @jwt_lifetime_seconds,
        "iss" => app_id
      }

      case Joken.encode_and_sign(claims, signer) do
        {:ok, jwt, _claims} -> {:ok, jwt}
        {:error, reason} -> {:error, {:jwt_failed, inspect(reason)}}
      end
    end
  end

  defp resolve_installation(repo, opts) do
    case Keyword.get(opts, :installation_id) do
      nil -> installation_id(repo, opts)
      id -> {:ok, id}
    end
  end

  defp request_opts(opts), do: Keyword.get(opts, :request_opts, [])

  defp request_installation_token(installation_id, jwt, opts) do
    case GithubClient.post(
           "/app/installations/#{installation_id}/access_tokens",
           %{},
           [token: jwt] ++ request_opts(opts)
         ) do
      {:ok, %{"token" => token} = body} ->
        expires_at = expires_at(body)

        Logger.info(
          "[github_app] minted an installation token for #{installation_id}, " <>
            "valid #{expires_at - System.os_time(:second)}s"
        )

        {:ok, TokenCache.put({:installation_token, installation_id}, token, expires_at)}

      {:ok, body} ->
        {:error, {:unexpected_body, "no token in #{inspect(body, limit: 5)}"}}

      # A private key that does not match the app id, or an app id that is not
      # ours, both land here — and neither improves on retry.
      {:error, {:unauthorized, message}} ->
        {:error,
         {:unauthorized,
          "GitHub rejected the app JWT (#{message}). Check GITHUB_APP_ID matches the key in " <>
            "GITHUB_PRIVATE_KEY_PATH."}}

      error ->
        error
    end
  end

  defp expires_at(%{"expires_at" => timestamp}) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> System.os_time(:second) + @assumed_token_lifetime_seconds
    end
  end

  defp expires_at(_body), do: System.os_time(:second) + @assumed_token_lifetime_seconds

  defp signer(pem) do
    {:ok, Joken.Signer.create("RS256", %{"pem" => pem})}
  rescue
    error -> {:error, {:bad_private_key, Exception.message(error)}}
  end

  defp fetch(nil, error), do: {:error, error}
  defp fetch(value, _error), do: {:ok, value}

  defp app_id, do: env("GITHUB_APP_ID")

  # The PEM inline takes precedence: a deploy with the key in an env var has
  # no file for GITHUB_PRIVATE_KEY_PATH to point at.
  defp private_key do
    case env("GITHUB_PRIVATE_KEY") do
      nil -> read_private_key(env("GITHUB_PRIVATE_KEY_PATH"))
      pem -> pem
    end
  end

  defp read_private_key(nil), do: nil

  defp read_private_key(path) do
    case File.read(path) do
      {:ok, pem} ->
        pem

      {:error, reason} ->
        Logger.error(
          "[github_app] cannot read GITHUB_PRIVATE_KEY_PATH #{path}: #{:file.format_error(reason)}"
        )

        nil
    end
  end

  defp private_key_error do
    case env("GITHUB_PRIVATE_KEY_PATH") do
      nil -> "neither GITHUB_PRIVATE_KEY nor GITHUB_PRIVATE_KEY_PATH is set"
      path -> "the private key at GITHUB_PRIVATE_KEY_PATH (#{path}) could not be read"
    end
  end

  # .env values are written with spaces around `=`, so trimming is not
  # optional — a leading space in an app id makes every JWT invalid.
  defp env(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end
end
