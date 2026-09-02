defmodule Mewtwo.GithubApp do
  @moduledoc "Handles GitHub App webhook verification"

  def verify_webhook_signature(payload, signature) do
    secret = System.get_env("GITHUB_WEBHOOK_SECRET")

    if secret do
      expected_signature = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload))

      # DEBUG
      IO.puts("DEBUG verify_webhook_signature:")
      IO.puts("  Secret: #{inspect(secret)}")
      IO.puts("  Expected: #{inspect(expected_signature)}")
      IO.puts("  Got: #{inspect(signature)}")
      IO.puts("  Match? #{expected_signature == signature}")

      Plug.Crypto.secure_compare(signature, expected_signature)
    else
      false
    end
  end
end
