defmodule PairingsEngine.Incidents.Incident do
  @moduledoc """
  Something that happened at a board, logged from a phone (Manubrium - see
  `PairingsEngine.Incidents` and docs/manubrium.md).

  Anchored to `tournament_id` / `round_number` / `board` rather than to the
  pairing alone, because the pairing is the one thing an arbiter may tear
  down and draw again: `pairing_id` is nilified when it goes, the round and
  board it happened on do not move. The two player ids are who sat there at
  the time, for the printed report phase 2 will build, and `white_name` /
  `black_name` are their names as the board showed them - kept because a
  snapshot restore recreates the players and nilifies the ids.

  `occurred_at` is the phone's clock when it is plausible, the server's when
  it is not; `inserted_at` is always when it arrived, which for an entry
  queued during a wifi outage can be a good deal later.
  """
  use Ecto.Schema

  schema "incidents" do
    field :round_number, :integer
    field :board, :integer
    field :kind, :string
    field :note, :string, default: ""
    field :white_name, :string, default: ""
    field :black_name, :string, default: ""
    field :occurred_at, :utc_datetime
    field :source, :string, default: "phone"
    field :enrollment_label, :string, default: ""
    field :client_id, :string
    # A photo is in `PairingsEngine.Incidents.Photo`, one at most; this says
    # whether there is one without loading it.
    field :has_photo, :boolean, default: false
    # When the arbiter marked it dealt with; nil while it is open. Desk-only:
    # the phones' incident list (`ManubriumApi.Json.incident/1`) does not
    # carry it, so the contract did not move.
    field :handled_at, :utc_datetime

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :pairing, PairingsEngine.Tournaments.Pairing
    belongs_to :white_player, PairingsEngine.Tournaments.Player
    belongs_to :black_player, PairingsEngine.Tournaments.Player
    belongs_to :enrollment, PairingsEngine.Mobile.Enrollment
    # The account that logged it, when the phone's code belongs to one.
    belongs_to :user, PairingsEngine.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
