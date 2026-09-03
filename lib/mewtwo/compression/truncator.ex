defmodule Mewtwo.Compression.Truncator do
  @moduledoc """
  Drops whole files from a diff until it fits a token budget.

  A large PR is rarely large because of code — it is large because of a
  lockfile, a build artifact or a vendored dependency. Rather than trimming
  every file evenly, this drops the least reviewable files first and leaves
  hand-written source intact for as long as possible.

  What survives is recorded in the returned metadata, and an explicit marker
  is prepended to the diff so agents know the picture is incomplete and do not
  claim the change is smaller than it is.
  """

  alias Mewtwo.TokenCounter

  # Lower tier is dropped first.
  @generated 0
  @asset 1
  @snapshot 2
  @test 3
  @source 4

  @lockfiles ~w(
    package-lock.json yarn.lock pnpm-lock.yaml npm-shrinkwrap.json
    Gemfile.lock mix.lock composer.lock poetry.lock Cargo.lock go.sum
    Pipfile.lock pubspec.lock
  )

  @generated_dirs ~w(dist/ build/ out/ vendor/ node_modules/ _build/ .next/ target/ coverage/)

  @asset_extensions ~w(
    .png .jpg .jpeg .gif .svg .ico .webp .avif .pdf .woff .woff2 .ttf .eot
    .mp4 .mp3 .wav .zip .gz .tar .bin .wasm
  )

  @doc """
  Trim `diff` to fit `budget` tokens

  Returns `{diff, metadata}` with metadata keys `:tokens`, `:dropped` (a list
  of `%{file:, tokens:, reason:}`) and `:dropped_tokens`.
  """
  def truncate(diff, budget) when is_binary(diff) and is_integer(budget) and budget > 0 do
    sections = split_files(diff)
    total = Enum.reduce(sections, 0, &(&1.tokens + &2))

    if total <= budget do
      {diff, %{tokens: total, dropped: [], dropped_tokens: 0}}
    else
      {kept, dropped} = drop_until_fits(sections, budget)
      rebuild(kept, dropped)
    end
  end

  # Falls back to reporting the size when there is no usable budget.
  def truncate(diff, _budget) when is_binary(diff) do
    {diff, %{tokens: TokenCounter.count_tokens(diff, :code), dropped: [], dropped_tokens: 0}}
  end

  # Sections are ordered as they appear; `preamble` holds anything before the
  # first file header so nothing is silently lost.
  defp split_files(diff) do
    diff
    |> String.split("\n")
    |> Enum.chunk_while(
      nil,
      fn line, current ->
        if file_header?(line) and current != nil do
          {:cont, Enum.reverse(current), [line]}
        else
          {:cont, [line | current || []]}
        end
      end,
      fn
        nil -> {:cont, []}
        current -> {:cont, Enum.reverse(current), nil}
      end
    )
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&build_section/1)
  end

  defp file_header?(line), do: String.starts_with?(line, ["--- a/", "--- /dev/null"])

  defp build_section(lines) do
    text = Enum.join(lines, "\n")
    file = filename(lines)

    %{
      file: file,
      text: text,
      tokens: TokenCounter.count_tokens(text, :code),
      tier: tier(file)
    }
  end

  # Prefer the new path from `+++ b/`, since a rename should be judged on where
  # the file ended up.
  defp filename(lines) do
    Enum.find_value(lines, "unknown", fn line ->
      cond do
        String.starts_with?(line, "+++ b/") -> String.replace_prefix(line, "+++ b/", "")
        String.starts_with?(line, "--- a/") -> String.replace_prefix(line, "--- a/", "")
        true -> nil
      end
    end)
  end

  defp tier(file) do
    basename = Path.basename(file)
    downcased = String.downcase(file)

    cond do
      basename in @lockfiles -> @generated
      String.contains?(downcased, @generated_dirs) -> @generated
      String.ends_with?(downcased, [".min.js", ".min.css", ".map"]) -> @generated
      String.ends_with?(downcased, @asset_extensions) -> @asset
      String.contains?(downcased, "__snapshots__") or String.ends_with?(downcased, ".snap") -> @snapshot
      test_file?(downcased) -> @test
      true -> @source
    end
  end

  defp test_file?(file) do
    String.starts_with?(file, ["test/", "spec/", "tests/"]) or
      String.contains?(file, "/test/") or
      String.contains?(file, "/spec/") or
      Regex.match?(~r/(_test|_spec|\.test|\.spec)\.[a-z]+$/, file)
  end

  # Drops the cheapest-to-lose sections first: lowest tier, and within a tier
  # the biggest file, so each drop buys back as much budget as possible.
  defp drop_until_fits(sections, budget) do
    order =
      sections
      |> Enum.with_index()
      |> Enum.sort_by(fn {section, index} -> {section.tier, -section.tokens, index} end)

    {dropped_indexes, _} =
      Enum.reduce_while(order, {[], Enum.reduce(sections, 0, &(&1.tokens + &2))}, fn
        {section, index}, {dropped, total} ->
          if total <= budget do
            {:halt, {dropped, total}}
          else
            {:cont, {[index | dropped], total - section.tokens}}
          end
      end)

    dropped_set = MapSet.new(dropped_indexes)

    sections
    |> Enum.with_index()
    |> Enum.split_with(fn {_section, index} -> not MapSet.member?(dropped_set, index) end)
    |> then(fn {kept, dropped} ->
      {Enum.map(kept, &elem(&1, 0)), Enum.map(dropped, &elem(&1, 0))}
    end)
  end

  defp rebuild(kept, dropped) do
    marker = dropped_marker(dropped)
    text = marker <> Enum.map_join(kept, "\n", & &1.text)

    metadata = %{
      tokens: TokenCounter.count_tokens(text, :code),
      dropped:
        Enum.map(dropped, fn section ->
          %{file: section.file, tokens: section.tokens, reason: reason(section.tier)}
        end),
      dropped_tokens: Enum.reduce(dropped, 0, &(&1.tokens + &2))
    }

    {text, metadata}
  end

  defp dropped_marker([]), do: ""

  defp dropped_marker(dropped) do
    listed =
      dropped
      |> Enum.take(20)
      |> Enum.map_join("\n", fn section ->
        "#  - #{section.file} (~#{section.tokens} tokens, #{reason(section.tier)})"
      end)

    remainder = length(dropped) - 20
    extra = if remainder > 0, do: "\n#  - ... and #{remainder} more\n", else: "\n"

    """
    # NOTE: this diff was truncated to fit the review token budget.
    # #{length(dropped)} file(s) were omitted entirely and you cannot see their contents:
    #{listed}#{extra}
    """
  end

  defp reason(@generated), do: "generated or vendored"
  defp reason(@asset), do: "binary or asset"
  defp reason(@snapshot), do: "snapshot"
  defp reason(@test), do: "test"
  defp reason(@source), do: "source, over budget"
end
