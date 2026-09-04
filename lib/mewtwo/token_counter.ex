defmodule Mewtwo.TokenCounter do
  @moduledoc """
  Token estimation for text/diffs: ~4 bytes per token, rounded up.

  Within ~10% of actual OpenAI-style token counts for typical code.

      iex> Mewtwo.TokenCounter.count_tokens("const x = 1", :code)
      3
  """

  @doc """
  Estimate tokens in `text`: `byte_size(String.trim(text)) / 4`, rounded up.

  The type hint is ignored — code and mixed content use the same heuristic.

  ## Examples

      iex> Mewtwo.TokenCounter.count_tokens("")
      0

      iex> Mewtwo.TokenCounter.count_tokens("   Hello world   ")
      3

      iex> Mewtwo.TokenCounter.count_tokens("const x = 1;", :code)
      3

  """
  def count_tokens(text, _type \\ :code) when is_binary(text) do
    (byte_size(String.trim(text)) / 4)
    |> Float.ceil()
    |> trunc()
  end
end
