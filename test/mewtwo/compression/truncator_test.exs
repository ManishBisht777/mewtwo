defmodule Mewtwo.Compression.TruncatorTest do
  use ExUnit.Case, async: true

  alias Mewtwo.Compression.Truncator

  defp file_section(path, line_count, prefix \\ "+") do
    body = Enum.map_join(1..line_count, "\n", fn i -> "#{prefix}  some content line #{i} here" end)

    "--- a/#{path}\n+++ b/#{path}\n@@ -1,#{line_count} +1,#{line_count} @@\n#{body}"
  end

  defp diff(sections), do: Enum.join(sections, "\n")

  describe "when the diff already fits" do
    test "returns it unchanged with nothing dropped" do
      original = diff([file_section("lib/a.ex", 5)])

      assert {result, meta} = Truncator.truncate(original, 100_000)
      assert result == original
      assert meta.dropped == []
      assert meta.dropped_tokens == 0
      assert meta.tokens > 0
    end
  end

  describe "drop order" do
    test "sacrifices a lockfile before source" do
      original =
        diff([
          file_section("lib/important.ex", 20),
          file_section("package-lock.json", 400)
        ])

      assert {result, meta} = Truncator.truncate(original, 500)

      assert [%{file: "package-lock.json", reason: "generated or vendored"}] = meta.dropped
      assert String.contains?(result, "lib/important.ex")
      refute String.contains?(result, "+++ b/package-lock.json")
    end

    test "sacrifices build output before source" do
      original = diff([file_section("lib/a.ex", 20), file_section("dist/bundle.js", 400)])

      assert {_result, meta} = Truncator.truncate(original, 500)
      assert [%{file: "dist/bundle.js", reason: "generated or vendored"}] = meta.dropped
    end

    test "sacrifices assets before source" do
      original = diff([file_section("lib/a.ex", 20), file_section("assets/logo.svg", 400)])

      assert {_result, meta} = Truncator.truncate(original, 500)
      assert [%{file: "assets/logo.svg", reason: "binary or asset"}] = meta.dropped
    end

    test "sacrifices tests before source" do
      original = diff([file_section("lib/a.ex", 20), file_section("test/a_test.exs", 400)])

      assert {_result, meta} = Truncator.truncate(original, 500)
      assert [%{file: "test/a_test.exs", reason: "test"}] = meta.dropped
    end

    test "drops the largest file first within a tier" do
      original =
        diff([
          file_section("lib/keep.ex", 10),
          file_section("dist/small.js", 50),
          file_section("dist/huge.js", 500)
        ])

      assert {_result, meta} = Truncator.truncate(original, 1_500)
      assert [%{file: "dist/huge.js"}] = meta.dropped
    end

    test "drops source only as a last resort, and says so" do
      original = diff([file_section("lib/a.ex", 300), file_section("lib/b.ex", 300)])

      # Budget fits one of the two files, so exactly one is sacrificed.
      assert {_result, meta} = Truncator.truncate(original, 2_500)
      assert [%{reason: "source, over budget"}] = meta.dropped
    end

    test "a budget smaller than any single file drops everything" do
      # Nothing can satisfy this; the caller's empty-diff guard is what turns
      # it into an error rather than a review of nothing.
      original = diff([file_section("lib/a.ex", 300)])

      assert {_result, meta} = Truncator.truncate(original, 10)
      assert length(meta.dropped) == 1
    end
  end

  describe "the resulting diff" do
    test "comes in under budget" do
      original =
        diff([
          file_section("lib/a.ex", 20),
          file_section("package-lock.json", 2_000),
          file_section("yarn.lock", 2_000)
        ])

      assert {_result, meta} = Truncator.truncate(original, 1_000)
      assert meta.tokens <= 1_000
    end

    test "carries a marker so agents know files are missing" do
      original = diff([file_section("lib/a.ex", 10), file_section("package-lock.json", 900)])

      assert {result, _meta} = Truncator.truncate(original, 400)

      assert result =~ "truncated to fit the review token budget"
      assert result =~ "package-lock.json"
      assert result =~ "cannot see their contents"
    end

    test "reports how many tokens were dropped" do
      original = diff([file_section("lib/a.ex", 10), file_section("package-lock.json", 900)])

      assert {_result, meta} = Truncator.truncate(original, 400)
      assert meta.dropped_tokens > 0
    end

    test "summarises rather than listing an unbounded number of files" do
      sections = for n <- 1..40, do: file_section("dist/chunk-#{n}.js", 60)
      original = diff([file_section("lib/a.ex", 5) | sections])

      assert {result, meta} = Truncator.truncate(original, 300)

      assert length(meta.dropped) == 40
      assert result =~ "and 20 more"
    end
  end

  describe "edge cases" do
    test "handles a diff with no file headers" do
      assert {result, meta} = Truncator.truncate("just some text", 100_000)
      assert result == "just some text"
      assert meta.dropped == []
    end

    test "handles an empty diff" do
      assert {"", meta} = Truncator.truncate("", 100_000)
      assert meta.dropped == []
    end

    test "handles a non-positive budget without dropping everything blindly" do
      original = diff([file_section("lib/a.ex", 5)])

      assert {result, meta} = Truncator.truncate(original, 0)
      assert result == original
      assert meta.dropped == []
    end

    test "recognises a new file added from /dev/null" do
      original = "--- /dev/null\n+++ b/lib/new.ex\n@@ -0,0 +1,2 @@\n+one\n+two"

      assert {result, meta} = Truncator.truncate(original, 100_000)
      assert result == original
      assert meta.dropped == []
    end
  end
end
