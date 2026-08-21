defmodule PairingsEngine.Tournaments.ForbiddenPairing do
  @moduledoc """
  A pair of players in a tournament who must never be paired against each
  other - an arbiter-configured exception (e.g. two players who share a
  household/club and shouldn't meet, or any other pairing the organiser
  wants ruled out). See `docs/forbidden-pairings.md` for the full picture:
  applied to the Swiss engine via a JaVaFo TRF "XXP" extension line (see
  `PairingsEngine.Pairing.forbidden_pairs_lines/2`), respected by
  `PairingsEngine.Keizer`, and ignored by `PairingsEngine.RoundRobin` by
  design (a round robin's schedule is fixed regardless).

  Order-insensitivity (`{a, b}` and `{b, a}` are the same forbidden pair) is
  enforced two ways: `PairingsEngine.Tournaments.add_forbidden_pairing/3`
  checks both orderings before insert (the nice-error fast path), and
  `changeset/2` normalizes storage order - the smaller id always goes in
  `player_a_id` - so the
  `forbidden_pairings_tournament_id_player_a_id_player_b_id_index` unique
  index on `(tournament_id, player_a_id, player_b_id)` is an
  order-insensitive DB-level guarantee (the atomic backstop for concurrent
  writes) without needing generated/computed columns.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "forbidden_pairings" do
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :player_a, PairingsEngine.Tournaments.Player
    belongs_to :player_b, PairingsEngine.Tournaments.Player
  end

  def changeset(forbidden_pairing, attrs) do
    forbidden_pairing
    |> cast(attrs, [:tournament_id, :player_a_id, :player_b_id])
    |> validate_required([:tournament_id, :player_a_id, :player_b_id])
    |> normalize_pair_order()
    |> validate_players_distinct()
    |> unique_constraint([:tournament_id, :player_a_id, :player_b_id],
      name: :forbidden_pairings_tournament_id_player_a_id_player_b_id_index,
      message: "this pair is already forbidden"
    )
  end

  # Always stores the smaller id in player_a_id, so {a, b} and {b, a} land
  # in the same row and the plain (tournament_id, player_a_id, player_b_id)
  # unique index below is order-insensitive by construction - see the
  # moduledoc.
  defp normalize_pair_order(changeset) do
    a = get_field(changeset, :player_a_id)
    b = get_field(changeset, :player_b_id)

    if a && b && a > b do
      changeset |> put_change(:player_a_id, b) |> put_change(:player_b_id, a)
    else
      changeset
    end
  end

  defp validate_players_distinct(changeset) do
    a = get_field(changeset, :player_a_id)
    b = get_field(changeset, :player_b_id)

    if a && b && a == b do
      add_error(changeset, :player_b_id, "must be a different player than player A")
    else
      changeset
    end
  end
end
