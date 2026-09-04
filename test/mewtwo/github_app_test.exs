defmodule Mewtwo.GithubAppTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mewtwo.GithubApp
  alias Mewtwo.GithubApp.TokenCache

  # A key generated here, so these tests do not depend on the repository's
  # real .pem being present. Generated once for the module: RSA keygen is the
  # slowest thing in this file by an order of magnitude.
  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    %{pem: pem}
  end

  setup do
    previous =
      Map.new(
        ["GITHUB_APP_ID", "GITHUB_PRIVATE_KEY", "GITHUB_PRIVATE_KEY_PATH", "GITHUB_TOKEN"],
        &{&1, System.get_env(&1)}
      )

    TokenCache.clear()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      TokenCache.clear()
    end)

    :ok
  end

  defp configure(pem) do
    System.put_env("GITHUB_APP_ID", "123456")
    System.put_env("GITHUB_PRIVATE_KEY", pem)
  end

  # Records requests on the test process and answers them by path.
  defp plug(responses) do
    test = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      authorization = Plug.Conn.get_req_header(conn, "authorization") |> List.first()

      send(test, {:request, conn.method, conn.request_path, authorization, body})

      {status, response} = Map.fetch!(responses, conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end
  end

  defp expires_in(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.to_iso8601()
  end

  describe "configured?/0" do
    test "is false without an app id or key" do
      refute GithubApp.configured?()
    end

    test "is false with an id but no key" do
      System.put_env("GITHUB_APP_ID", "123456")

      refute GithubApp.configured?()
    end

    test "is true with both", %{pem: pem} do
      configure(pem)

      assert GithubApp.configured?()
    end

    test "ignores the whitespace .env leaves around values", %{pem: pem} do
      System.put_env("GITHUB_APP_ID", "   ")
      System.put_env("GITHUB_PRIVATE_KEY", pem)

      # A blank app id would otherwise sign a JWT with iss: "   ", which
      # GitHub rejects with an unhelpful 401.
      refute GithubApp.configured?()
    end
  end

  describe "jwt/0" do
    test "signs a JWT the app's public key verifies", %{pem: pem} do
      configure(pem)

      assert {:ok, jwt} = GithubApp.jwt()

      signer = Joken.Signer.create("RS256", %{"pem" => pem})
      assert {:ok, claims} = Joken.verify(jwt, signer)

      assert claims["iss"] == "123456"
      # Back-dated against clock skew, and inside GitHub's 10-minute ceiling.
      now = System.os_time(:second)
      assert claims["iat"] <= now
      assert claims["exp"] > now
      assert claims["exp"] - claims["iat"] <= 600
    end

    test "reports a missing app id rather than signing an anonymous JWT", %{pem: pem} do
      System.put_env("GITHUB_PRIVATE_KEY", pem)

      assert {:error, {:missing_config, message}} = GithubApp.jwt()
      assert message =~ "GITHUB_APP_ID"
    end

    test "reports a missing key" do
      System.put_env("GITHUB_APP_ID", "123456")

      assert {:error, {:missing_config, message}} = GithubApp.jwt()
      assert message =~ "GITHUB_PRIVATE_KEY"
    end

    test "reports an unreadable key file" do
      System.put_env("GITHUB_APP_ID", "123456")
      System.put_env("GITHUB_PRIVATE_KEY_PATH", "/nope/not/here.pem")

      log = capture_log(fn -> assert {:error, {:missing_config, _}} = GithubApp.jwt() end)

      assert log =~ "cannot read GITHUB_PRIVATE_KEY_PATH"
    end

    test "reports a key that is not a private key" do
      System.put_env("GITHUB_APP_ID", "123456")
      System.put_env("GITHUB_PRIVATE_KEY", "-----BEGIN RSA PRIVATE KEY-----\nnope\n")

      assert {:error, {:bad_private_key, _}} = GithubApp.jwt()
    end

    test "reads the key from a file when given a path", %{pem: pem} do
      path = Path.join(System.tmp_dir!(), "mewtwo-test-#{System.unique_integer([:positive])}.pem")
      File.write!(path, pem)
      on_exit(fn -> File.rm(path) end)

      System.put_env("GITHUB_APP_ID", "123456")
      System.put_env("GITHUB_PRIVATE_KEY_PATH", path)

      assert {:ok, _jwt} = GithubApp.jwt()
    end
  end

  describe "token_for/2" do
    test "mints an installation token, authenticating as the app", %{pem: pem} do
      configure(pem)

      responses = %{
        "/repos/owner/name/installation" => {200, %{"id" => 42}},
        "/app/installations/42/access_tokens" =>
          {201, %{"token" => "ghs_installation", "expires_at" => expires_in(3600)}}
      }

      assert {:ok, "ghs_installation"} =
               GithubApp.token_for("owner/name", request_opts: [plug: plug(responses)])

      # Both hops authenticate with the JWT as a bearer credential; `token`
      # is not accepted for a JWT.
      assert_received {:request, "GET", "/repos/owner/name/installation", auth, _}
      assert "Bearer ey" <> _ = auth

      assert_received {:request, "POST", "/app/installations/42/access_tokens", auth, _}
      assert "Bearer ey" <> _ = auth
    end

    test "skips the lookup when the webhook already told us the installation", %{pem: pem} do
      configure(pem)

      responses = %{
        "/app/installations/99/access_tokens" =>
          {201, %{"token" => "ghs_from_webhook", "expires_at" => expires_in(3600)}}
      }

      assert {:ok, "ghs_from_webhook"} =
               GithubApp.token_for("owner/name",
                 installation_id: 99,
                 request_opts: [plug: plug(responses)]
               )

      assert_received {:request, "POST", "/app/installations/99/access_tokens", _, _}
      refute_received {:request, "GET", "/repos/owner/name/installation", _, _}
    end

    test "reports no app rather than erroring when none is configured" do
      assert GithubApp.token_for("owner/name") == :no_app
    end

    test "explains an app that is not installed on the repo", %{pem: pem} do
      configure(pem)

      responses = %{"/repos/owner/name/installation" => {404, %{"message" => "Not Found"}}}

      capture_log(fn ->
        assert {:error, {:not_installed, message}} =
                 GithubApp.token_for("owner/name", request_opts: [plug: plug(responses)])

        assert message =~ "not installed on owner/name"
      end)
    end

    test "explains a key that does not match the app id", %{pem: pem} do
      configure(pem)

      responses = %{
        "/app/installations/42/access_tokens" =>
          {401, %{"message" => "A JSON web token could not be decoded"}}
      }

      capture_log(fn ->
        assert {:error, {:unauthorized, message}} =
                 GithubApp.token_for("owner/name",
                   installation_id: 42,
                   request_opts: [plug: plug(responses)]
                 )

        assert message =~ "GITHUB_APP_ID matches the key"
      end)
    end

    test "errors when the mint succeeds but carries no token", %{pem: pem} do
      configure(pem)

      responses = %{"/app/installations/42/access_tokens" => {201, %{"expires_at" => "later"}}}

      assert {:error, {:unexpected_body, _}} =
               GithubApp.token_for("owner/name",
                 installation_id: 42,
                 request_opts: [plug: plug(responses)]
               )
    end
  end

  describe "token caching" do
    test "reuses a live token instead of minting one per request", %{pem: pem} do
      configure(pem)

      responses = %{
        "/app/installations/42/access_tokens" =>
          {201, %{"token" => "ghs_cached", "expires_at" => expires_in(3600)}}
      }

      opts = [installation_id: 42, request_opts: [plug: plug(responses)]]

      assert {:ok, "ghs_cached"} = GithubApp.token_for("owner/name", opts)
      assert {:ok, "ghs_cached"} = GithubApp.token_for("owner/name", opts)

      assert_received {:request, "POST", _, _, _}
      refute_received {:request, "POST", _, _, _}
    end

    test "re-mints a token that is about to expire", %{pem: pem} do
      configure(pem)

      # Inside the renewal margin: still valid, but not for long enough to
      # hand to a request that may take seconds to complete.
      about_to_expire = TokenCache.renew_margin_seconds() - 10

      responses = %{
        "/app/installations/42/access_tokens" =>
          {201, %{"token" => "ghs_short", "expires_at" => expires_in(about_to_expire)}}
      }

      opts = [installation_id: 42, request_opts: [plug: plug(responses)]]

      assert {:ok, "ghs_short"} = GithubApp.token_for("owner/name", opts)
      assert {:ok, "ghs_short"} = GithubApp.token_for("owner/name", opts)

      assert_received {:request, "POST", _, _, _}
      assert_received {:request, "POST", _, _, _}
    end

    test "does not cache across installations", %{pem: pem} do
      configure(pem)

      responses = %{
        "/app/installations/1/access_tokens" =>
          {201, %{"token" => "ghs_one", "expires_at" => expires_in(3600)}},
        "/app/installations/2/access_tokens" =>
          {201, %{"token" => "ghs_two", "expires_at" => expires_in(3600)}}
      }

      request_opts = [plug: plug(responses)]

      assert {:ok, "ghs_one"} =
               GithubApp.token_for("a/one", installation_id: 1, request_opts: request_opts)

      assert {:ok, "ghs_two"} =
               GithubApp.token_for("b/two", installation_id: 2, request_opts: request_opts)
    end
  end

  describe "verify_webhook_signature/2" do
    setup do
      System.put_env("GITHUB_WEBHOOK_SECRET", "shhh")
      on_exit(fn -> System.delete_env("GITHUB_WEBHOOK_SECRET") end)
    end

    defp signature(payload, secret) do
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, payload), case: :lower)
    end

    test "accepts a payload signed with the secret" do
      assert GithubApp.verify_webhook_signature("body", signature("body", "shhh"))
    end

    test "rejects a signature from a different secret" do
      refute GithubApp.verify_webhook_signature("body", signature("body", "guess"))
    end

    test "rejects a signature for different content" do
      refute GithubApp.verify_webhook_signature("tampered", signature("body", "shhh"))
    end

    test "rejects a missing signature instead of raising" do
      refute GithubApp.verify_webhook_signature("body", nil)
    end

    test "rejects everything when no secret is configured" do
      System.delete_env("GITHUB_WEBHOOK_SECRET")

      refute GithubApp.verify_webhook_signature("body", signature("body", "shhh"))
    end
  end
end
