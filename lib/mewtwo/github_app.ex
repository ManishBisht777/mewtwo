defmodule Mewtwo.GithubApp do
  @moduledoc "Handles GitHub App webhook verification"

  def verify_webhook_signature(payload, "sha256=" <> _ = signature) do
    case System.get_env("GITHUB_WEBHOOK_SECRET") do
      nil ->
        false

      secret ->
        expected =
          "sha256=" <>
            Base.encode16(
              :crypto.mac(:hmac, :sha256, secret, payload),
              case: :lower
            )

        Plug.Crypto.secure_compare(signature, expected)
    end
  end

  def verify_webhook_signature(_payload, _signature), do: false
end
