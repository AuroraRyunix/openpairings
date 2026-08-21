defmodule PairingsEngine.Tournaments.Round do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rounds" do
    field :number, :integer
    field :date, :string, default: ""
    field :status, :string, default: "pairing"
    # When this round becomes visible on the public pairings page - see
    # `PairingsEngine.Tournaments.compute_published_at/2` (set once, at
    # pairing time, from the tournament's `publish_mode`) and
    # `round_published?/2` (the actual visibility check, which ignores
    # this entirely in "immediate" mode - see that function's own
    # comment for why nil-by-default here is safe for every tournament
    # that predates this field). `nil` means "not published" under any
    # OTHER mode; never published retroactively by a background job -
    # visibility is just "is this timestamp in the past", checked live.
    field :published_at, :utc_datetime

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    has_many :pairings, PairingsEngine.Tournaments.Pairing
  end

  def changeset(round, attrs) do
    round
    |> cast(attrs, [:number, :date, :status, :published_at])
    |> validate_required([:number])
    |> validate_inclusion(:status, ~w(pairing playing finished))
  end
end
