defmodule Willy.Repo do
  use Ecto.Repo,
    otp_app: :willy,
    adapter: Ecto.Adapters.Postgres
end
