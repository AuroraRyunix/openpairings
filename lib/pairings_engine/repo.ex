defmodule PairingsEngine.Repo do
  use Ecto.Repo,
    otp_app: :pairings_engine,
    adapter: Ecto.Adapters.SQLite3
end
