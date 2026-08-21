defmodule PairingsEngine.RatingRefresh do
  @moduledoc """
  Bulk rating refresh (SWAR "Rafraichir toutes les cotes"): re-looks-up every
  registered player against the locally-synced FIDE rating list
  (`PairingsEngine.Fide`, see `docs/kbsb-sync.md`) and proposes changes,
  without writing anything until `apply/2` is called. See
  `docs/rating-refresh.md`.

  Matching mirrors the per-player "Refresh" button already on the player
  registration dialog (`PairingsEngineWeb.PlayersLive.handle_event/3`
  `"refresh_edit_fide"`), except by exact id instead of name search, and
  across every player at once:

    * `player.fide_id` → `fide_players` (exact match): proposes a new
      `fide_rating` when it differs, and a new `title` when the FIDE record
      has one (never proposes *blanking* a title FIDE doesn't carry). The
      rating proposed is the one matching the tournament's own cadence
      (`tournament.standard` - Standard/Rapid/Blitz, see
      `PairingsEngine.Fide.rating_for_tempo/2`), falling back to Standard
      when the player has no rating in that specific list.

  `national_rating` is deliberately NOT refreshed from the KBSB list. It is
  an import/manual-entry artifact: SWAR's own ELO lands there on import (see
  `PairingsEngine.SwarImport`), the KBSB search pre-fills it when a player is
  registered off the list, and an arbiter can type it. A bulk button that
  silently rewrote it afterwards made it look like OpenPairings maintains a
  live national-rating system, which it does not. Clubs are a separate
  gesture with its own button - see `PairingsEngine.ClubRefresh`.

  A player with no `fide_id` set (or whose id has no match in the list)
  contributes no proposals and counts as "unmatched" in the summary.
  """

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Fide
  alias PairingsEngine.Fide.FidePlayer

  @derive {Inspect, only: [:field, :old, :new]}
  defstruct [:player, :field, :old, :new]

  @type t :: %__MODULE__{player: Player.t(), field: atom(), old: term(), new: term()}

  @type summary :: %{
          proposals: [t()],
          checked: non_neg_integer(),
          changed: non_neg_integer(),
          unmatched: non_neg_integer()
        }

  @doc """
  Looks up every player in `tournament` against the local FIDE copy and
  returns a summary: `%{proposals:, checked:, changed:, unmatched:}` -
  `changed` is the number of players with at least one proposed change,
  `unmatched` the number with no FIDE-id match at all.
  Writes nothing; pair with `apply/2` to commit.
  """
  @spec dry_run(Tournaments.Tournament.t()) :: summary()
  def dry_run(tournament) do
    results =
      tournament.id
      |> Tournaments.list_players()
      |> Enum.map(&player_proposals(&1, tournament.standard))

    %{
      proposals: Enum.flat_map(results, & &1.proposals),
      checked: length(results),
      changed: Enum.count(results, &(&1.proposals != [])),
      unmatched: Enum.count(results, &(not &1.matched?))
    }
  end

  defp player_proposals(player, standard) do
    fide = fide_match(player)

    proposals =
      []
      |> maybe_add(
        player,
        :fide_rating,
        player.fide_rating,
        Fide.rating_for_tempo(fide, standard)
      )
      |> maybe_add_title(player, fide)

    %{proposals: proposals, matched?: fide != nil}
  end

  defp fide_match(%Player{fide_id: nil}), do: nil
  defp fide_match(%Player{fide_id: fide_id}), do: Repo.get(FidePlayer, fide_id)

  # Only proposes a title when the FIDE record actually carries one - never
  # proposes clearing a locally-set title just because the FIDE row is blank.
  defp maybe_add_title(list, player, %FidePlayer{title: t}) when t not in [nil, ""],
    do: maybe_add(list, player, :title, player.title, t)

  defp maybe_add_title(list, _player, _fide), do: list

  defp maybe_add(list, _player, _field, _old, nil), do: list
  defp maybe_add(list, _player, _field, old, new) when old == new, do: list

  defp maybe_add(list, player, field, old, new) do
    list ++ [%__MODULE__{player: player, field: field, old: old, new: new}]
  end

  @doc """
  Applies `proposals` (as returned in a `dry_run/1` summary's `:proposals`)
  to `tournament` in a single transaction, firing exactly one
  `tournament_changed` broadcast (via
  `PairingsEngine.Tournaments.bulk_update_players/2`). Proposals for the
  same player are grouped into a single update.
  """
  @spec apply(Tournaments.Tournament.t(), [t()]) :: {:ok, [Player.t()]} | {:error, term()}
  def apply(tournament, proposals) do
    updates =
      proposals
      |> Enum.group_by(& &1.player.id)
      |> Enum.map(fn {_player_id, props} ->
        player = hd(props).player
        attrs = Map.new(props, &{&1.field, &1.new})
        {player, attrs}
      end)

    Tournaments.bulk_update_players(tournament.id, updates)
  end
end
