# :dotenv loads the real .env, which configures the live GitHub App. Left in
# place, any test that reached the publish path would mint a real installation
# token against api.github.com. Tests that exercise app auth set these
# themselves, with a key generated for the test.
Enum.each(
  ["GITHUB_APP_ID", "GITHUB_PRIVATE_KEY", "GITHUB_PRIVATE_KEY_PATH"],
  &System.delete_env/1
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Mewtwo.Repo, :manual)
