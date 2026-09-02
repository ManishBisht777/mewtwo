defmodule Mewtwo.GithubApp do
  @moduledoc "Handles GitHub App webhook verification"

  def verify_webhook_signature(payload, signature) do
    secret = System.get_env("GITHUB_WEBHOOK_SECRET")

    if secret do
      expected_signature = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload), case: :lower)
      Plug.Crypto.secure_compare(signature, expected_signature)
    else
      false
    end
  end
end
