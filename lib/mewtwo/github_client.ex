defmodule Mewtwo.GithubClient do
  @moduledoc """
  GitHub REST API client

  Authentication, in order of preference:

    1. a `:token` option — a GitHub App installation token or JWT from
       `Mewtwo.GithubApp`, sent as `Bearer`. This is how the app acts as
       itself, so review comments are authored by the app rather than by
       whoever owns the personal token.
    2. `GITHUB_TOKEN`, sent as `token` — a personal access token.
    3. nothing at all, which is enough to read public repositories at 60
       requests/hour.

  A token is required for private repos, higher rate limits, and any write.
  """

  require Logger

  @github_api_url "https://api.github.com"

  # Caps how far get_paginated/2 will follow Link: rel="next". 10 pages at
  # GitHub's per_page=100 is 1000 items, well past any real PR's file count.
  @default_max_pages 10

  @default_headers [
    {"Accept", "application/vnd.github+json"},
    {"X-GitHub-Api-Version", "2022-11-28"}
  ]

  @doc """
  GET a single API path

  Options are passed through to `Req.get/2`. A `:headers` option is merged
  over the default headers (case-insensitively), so callers can override
  `Accept` to request an alternate media type such as a raw diff, and a
  `:token` option authenticates as a GitHub App instead of as `GITHUB_TOKEN`.

  Returns `{:ok, body}` or `{:error, reason}`. Unlike a bare `Req.get/2`,
  a non-2xx status is an error rather than a successful response carrying
  an error payload.
  """
  def get(path, opts \\ []) do
    with {:ok, response} <- do_get(@github_api_url <> path, opts) do
      {:ok, response.body}
    end
  end

  @doc """
  GET an API path, following `Link: rel="next"` to collect pages

  Options:
    - `:max_pages` — stop after this many pages (default #{@default_max_pages})

  Returns `{:ok, items}` with the pages concatenated, or `{:error, reason}`.

  The page cap matters: pointed at a listing endpoint such as
  `/pulls?state=closed`, an uncapped follow walks the repository's entire
  history and can exhaust the hourly rate limit in a single call.
  """
  def get_paginated(path, opts \\ []) do
    {max_pages, req_opts} = Keyword.pop(opts, :max_pages, @default_max_pages)

    collect_pages(@github_api_url <> path, req_opts, [], max_pages)
  end

  @doc """
  POST a JSON body to a single API path

  Options are passed through to `Req.request/1`, so `:headers` and `:token`
  behave exactly as in `get/2`.

  Returns `{:ok, body}` or `{:error, reason}`, with non-2xx mapped to the same
  reasons `get/2` uses — notably `{:unauthorized, msg}` for a missing or
  under-scoped token and `{:http_error, 422, msg}` for a body GitHub rejects.

  Every write needs a token: anonymous requests can read public repositories
  but cannot post. See `authenticated?/0`.
  """
  def post(path, body, opts \\ []) do
    with {:ok, response} <- do_request(:post, @github_api_url <> path, [json: body] ++ opts) do
      {:ok, response.body}
    end
  end

  @doc """
  Whether a usable `GITHUB_TOKEN` is present

  Worth checking before a write, so a missing token is reported as such
  instead of arriving as a confusing 401 from GitHub.
  """
  def authenticated?, do: env_token() != nil

  defp collect_pages(nil, _opts, acc, _remaining), do: {:ok, acc}

  defp collect_pages(url, _opts, acc, 0) do
    Logger.warning(
      "GitHub pagination stopped at the page cap with #{length(acc)} items; " <>
        "next page would have been #{url}"
    )

    {:ok, acc}
  end

  defp collect_pages(url, opts, acc, remaining) do
    with {:ok, response} <- do_get(url, opts),
         {:ok, items} <- as_list(response.body, url) do
      collect_pages(next_page_url(response.headers), opts, acc ++ items, remaining - 1)
    end
  end

  defp as_list(body, _url) when is_list(body), do: {:ok, body}

  defp as_list(body, url) do
    {:error, {:unexpected_body, "expected a JSON array from #{url}, got #{type_of(body)}"}}
  end

  defp do_get(url, opts), do: do_request(:get, url, opts)

  defp do_request(method, url, opts) do
    {overrides, opts} = Keyword.pop(opts, :headers, [])
    {token, req_opts} = Keyword.pop(opts, :token)
    headers = merge_headers(@default_headers ++ auth_headers(token), overrides)

    case Req.request([method: method, url: url, headers: headers] ++ req_opts) do
      {:ok, response} -> check_status(response, url)
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  # GitHub answers 401/403/404 with a 200-shaped JSON error body, so without
  # this check a bad token or a missing PR flows downstream as if it succeeded.
  defp check_status(%Req.Response{status: status} = response, _url) when status in 200..299 do
    {:ok, response}
  end

  defp check_status(%Req.Response{status: status} = response, url) do
    message = error_message(response.body)

    reason =
      cond do
        # Carries seconds-until-reset so callers can wait it out rather than
        # burning retries on a limit that clears in minutes, not seconds.
        rate_limited?(response) -> {:rate_limited, message, seconds_until_reset(response)}
        status in [401, 403] -> {:unauthorized, message}
        status == 404 -> {:not_found, message}
        true -> {:http_error, status, message}
      end

    Logger.error("GitHub #{status} on #{url}: #{message}")
    {:error, reason}
  end

  defp rate_limited?(%Req.Response{status: status} = response) do
    status in [403, 429] and Req.Response.get_header(response, "x-ratelimit-remaining") == ["0"]
  end

  # `retry-after` covers secondary limits; `x-ratelimit-reset` is an epoch
  # second for the primary hourly quota. Falls back to a minute when neither
  # header is present.
  defp seconds_until_reset(response) do
    with nil <- retry_after(response),
         nil <- reset_at(response) do
      60
    else
      seconds -> seconds
    end
  end

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, _} <- Integer.parse(value),
         true <- seconds > 0 do
      seconds
    else
      _ -> nil
    end
  end

  defp reset_at(response) do
    with [value | _] <- Req.Response.get_header(response, "x-ratelimit-reset"),
         {epoch, _} <- Integer.parse(value) do
      max(epoch - System.os_time(:second), 1)
    else
      _ -> nil
    end
  end

  defp error_message(%{"message" => message}), do: message
  defp error_message(body) when is_binary(body), do: String.slice(body, 0..200)
  defp error_message(body), do: inspect(body, printable_limit: 200)

  # Later entries win, compared case-insensitively, so a caller-supplied
  # Accept replaces the default rather than being sent alongside it.
  defp merge_headers(defaults, overrides) do
    overridden =
      overrides
      |> Enum.map(fn {key, _} -> String.downcase(to_string(key)) end)
      |> MapSet.new()

    Enum.reject(defaults, fn {key, _} ->
      MapSet.member?(overridden, String.downcase(to_string(key)))
    end) ++ overrides
  end

  # A GitHub App installation token or JWT is a bearer credential; a personal
  # access token uses the older `token` scheme. GitHub accepts `Bearer` for
  # both, but not `token` for a JWT.
  defp auth_headers(nil) do
    case env_token() do
      nil -> []
      token -> [{"Authorization", "token #{token}"}]
    end
  end

  defp auth_headers(token) when is_binary(token) do
    [{"Authorization", "Bearer #{token}"}]
  end

  # An unset *or blank* GITHUB_TOKEN must yield no Authorization header at all.
  # Sending `token ` with an empty value gets a hard 401 from GitHub instead of
  # being treated as an anonymous request.
  defp env_token do
    case System.get_env("GITHUB_TOKEN") do
      nil ->
        nil

      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  defp next_page_url(headers) do
    case Enum.find(headers, fn {key, _} -> String.downcase(key) == "link" end) do
      {_, link_header} -> parse_next_link(link_header)
      nil -> nil
    end
  end

  defp parse_next_link(link_header) do
    link_header
    |> List.wrap()
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.find_value(fn link ->
      if String.contains?(link, ~s(rel="next")) do
        case Regex.run(~r/<(.+?)>/, link) do
          [_, url] -> url
          _ -> nil
        end
      end
    end)
  end

  defp type_of(body) when is_map(body), do: "a JSON object"
  defp type_of(body) when is_binary(body), do: "a #{byte_size(body)}-byte string"
  defp type_of(body), do: inspect(body, printable_limit: 100)
end
