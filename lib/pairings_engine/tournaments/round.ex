defmodule PairingsEngine.Tournaments.Round do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rounds" do
    field :number, :integer
    field :date, :string, default: ""
    field :status, :string, default: "pairing"
    # When this round becomes visible on the public pairings page - see
    # `PairingsEngine.Tournaments.compute_published_at/2` (set once, at
    # pairing time, from the tournament's `publish_mode` and its delay) and
    # `round_published?/2` (the actual visibility check). `nil` means "not
    # published"; never published retroactively by a background job -
    # visibility is just "is this timestamp in the past", checked live.
    field :published_at, :utc_datetime

    # The "Results round N" switch: whether the results typed into this
    # round may travel with its published pairings. `false` for every new
    # round - the pairings still publish, the boards go out without results
    # (`PairingsEngine.Snapshot` withholds them). Read through
    # `Tournaments.results_public?/2`, never directly: public standings after
    # this round, and the automation's results step, make the results public
    # whatever this says.
    #
    # Written only by `Tournaments.publish_results/2`,
    # `unpublish_results/2` and the pairings-unpublish cascades, and NOT cast
    # by `changeset/2` - same reasoning as `Tournament.standings_through`.
    # The migration that added it backfilled `true` on every round already
    # published, because those results were public at the time.
    field :results_public, :boolean, default: false

    # The highest level the automation may bring this round to - set when the
    # arbiter chooses a level on the Pairings page that is BELOW what the
    # automation would give the round (`Tournaments.set_round_publish_level/3`),
    # so a round taken down by hand stays down. `nil` - the usual case - is
    # no limit. Only the automation's derived steps read it (results live,
    # standings once finished); what the arbiter chose by hand is stored in
    # the fields above and never capped. Not cast, like `results_public`.
    field :publish_cap, :integer

    # What the pairing engine reported about its own decision, captured when
    # the round was paired - see `PairingsEngine.Pairing.explanation/3`. Only
    # Ainalrami produces one; a JaVaFo round, and every round paired before
    # this column existed, leaves it nil and the rationale page falls back to
    # reconstructing brackets from the round's inputs and outputs.
    #
    # Stored rather than recomputed because it is a record of what happened,
    # not a derivation of current state: a round can be edited by hand
    # afterwards (`pairing.players_swapped` and friends), and re-deriving
    # then would explain a pairing the engine never produced.
    field :explanation, :map

    # The extra points each player was paired with in this round - the
    # virtual points handed to the engine as that round's `XXA` value -
    # `%{"player id" => points}`, non-zero entries only, so `%{}` is "paired
    # on game points alone". Written when a Swiss round is paired
    # (`PairingsEngine.Pairing`) and by the SWAR import (each `[RONDE]`
    # record's `XtraPts`), read back as the history every later round's
    # `XXA` line carries (`Pairing.accelerations/3`). Stored for the same
    # reason `explanation` is: a player's extra points change between
    # rounds (SWAR's "remove half a point"), and the engine needs what each
    # past round was paired WITH, not what the player holds today. Nil for a
    # round paired before the column existed, or by hand. See
    # docs/extra-points.md. Not cast.
    field :virtual_points, :map

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    has_many :pairings, PairingsEngine.Tournaments.Pairing
    # A team round's matches (`PairingsEngine.TeamRoundRobin`); none for an
    # individual round.
    has_many :matches, PairingsEngine.Tournaments.Match
  end

  def changeset(round, attrs) do
    round
    |> cast(attrs, [:number, :date, :status, :published_at, :explanation])
    |> validate_required([:number])
    |> validate_inclusion(:status, ~w(pairing playing finished))
  end
end
