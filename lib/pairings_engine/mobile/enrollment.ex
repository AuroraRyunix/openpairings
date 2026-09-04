defmodule PairingsEngine.Mobile.Enrollment do
  @moduledoc """
  A no-account "enrolled phone" grant for mobile result entry, scoped to one
  tournament (see `PairingsEngine.Mobile`). `token` is the unguessable secret
  carried in the QR/URL; `code` is the short numeric password a helper can type
  instead of scanning. Valid until `expires_at`, or until `revoked_at` is set.

  `level` is what the code may DO, not who holds it - see
  `PairingsEngine.Mobile.permit_result/4` for the actual rules:

    * `"helper"` - fill a blank board only, latest paired round only.
    * `"deputy"` - enter and correct, any paired round (today's original,
      unrestricted behaviour).

  `board_from`/`board_to` are an orthogonal, optional restriction on top of
  either level - both `nil` means every board.

  `claimed_at` is who got here first, not who is allowed: `nil` means no
  phone has used this code yet; once set (by `PairingsEngine.Mobile.claim/1`),
  every later phone presenting the same token or code is refused rather than
  handed a session too - see that function's docs for why the write that
  sets it has to be the thing that decides, not a read beforehand.
  """
  use Ecto.Schema

  schema "mobile_enrollments" do
    field :token, :string
    field :code, :string
    field :label, :string, default: ""
    field :level, :string, default: "helper"
    field :board_from, :integer
    field :board_to, :integer
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :claimed_at, :utc_datetime

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament

    timestamps(type: :utc_datetime)
  end
end
