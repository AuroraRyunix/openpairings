defmodule PairingsEngine.Manubrium.ConnectCode do
  @moduledoc """
  "Connect Manubrium": a one-time secret an account shows as a QR code, for
  the app to trade for a device token (`PairingsEngine.Manubrium.redeem/3`).

  Only the secret's hash is stored. It is good for a few minutes and for
  one trade, whichever ends first; `used_at` is set by the trade itself, in
  the same statement that checks it was not set yet.
  """
  use Ecto.Schema

  schema "manubrium_connect_codes" do
    field :secret_hash, :string, redact: true
    field :base_url, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, PairingsEngine.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
