defmodule Mewtwo.GithubClient do
  @moduledoc "GitHub API client with app authentication"

  require Logger

  @github_api_url "https://api.github.com"

  def get(path, opts \\ []) do
    url = @github_api_url <> path
    headers = auth_headers()

    case Req.get(url, [headers: headers] ++ opts) do
      {:ok, response} -> {:ok, response.body}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_paginated(path, opts \\ []) do
    url = @github_api_url <> path
    headers = auth_headers()

    case Req.get(url, [headers: headers] ++ opts) do
      {:ok, response} ->
        items = response.body
        next_url = get_next_page_url(response.headers)

        if next_url do
          case fetch_remaining_pages(next_url, headers, []) do
            {:ok, remaining} -> {:ok, items ++ remaining}
            error -> error
          end
        else
          {:ok, items}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_remaining_pages(url, headers, acc) when url == nil, do: {:ok, acc}

  defp fetch_remaining_pages(url, headers, acc) do
    case Req.get(url, headers: headers) do
      {:ok, response} ->
        items = response.body
        next_url = get_next_page_url(response.headers)
        fetch_remaining_pages(next_url, headers, acc ++ items)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_next_page_url(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "link" end)
    |> case do
      {_, link_header} -> parse_next_link(link_header)
      nil -> nil
    end
  end

  defp parse_next_link(link_header) do
    link_header
    |> String.split(",")
    |> Enum.find_map(fn link ->
      if String.contains?(link, "rel=\"next\"") do
        case Regex.run(~r/<(.+?)>/, link) do
          [_, url] -> url
          _ -> nil
        end
      end
    end)
  end

  defp auth_headers do
    token = System.get_env("GITHUB_TOKEN")
    accept = "application/vnd.github+json"

    [
      {"Accept", accept},
      {"Authorization", "token #{token}"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end
end
