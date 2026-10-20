defmodule PairingsEngine.Manubrium.Device do
  @moduledoc """
  A phone with the Manubrium app on it, connected to an account
  (`PairingsEngine.Manubrium`). It holds a long-lived bearer token; this row
  holds the token's SHA-256 and its last four characters, so the account
  page can tell two phones apart without the server ever being able to
  hand the token out again.

  Revoked is final: a revoked device is refused from its next request on
  and must be connected again, which makes a new row.
  """
  use Ecto.Schema

  schema "manubrium_devices" do
    field :name, :string, default: ""
    field :platform, :string, default: ""
    field :token_hash, :string, redact: true
    field :token_hint, :string, default: ""
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, PairingsEngine.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
