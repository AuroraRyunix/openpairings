defmodule PairingsEngine.Mobile.Enrollment do
  @moduledoc """
  A no-account "enrolled phone" grant for mobile result entry, scoped to one
  tournament (see `PairingsEngine.Mobile`). `token` is the unguessable secret
  carried in the QR/URL; `code` is the short numeric password a helper can type
  instead of scanning. Valid until `expires_at`, or until `revoked_at` is set.
  """
  use Ecto.Schema

  schema "mobile_enrollments" do
    field :token, :string
    field :code, :string
    field :label, :string, default: ""
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament

    timestamps(type: :utc_datetime)
  end
end
