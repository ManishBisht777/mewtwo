defmodule Mewtwo.Repo do
  use Ecto.Repo,
    otp_app: :mewtwo,
    adapter: Ecto.Adapters.Postgres
end
