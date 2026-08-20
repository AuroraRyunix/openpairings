defmodule PairingsEngine.ClubRefresh do
  @moduledoc """
  Bulk club refresh: re-looks-up every registered player against the
  locally-synced KBSB list (`PairingsEngine.Kbsb`, see `docs/kbsb-sync.md`)
  and proposes club changes, without writing anything until `apply/2` is
  called.

  Deliberately the same shape as `PairingsEngine.RatingRefresh` — dry run,
  preview modal, apply — because it is the same gesture on a different
  column, and an arbiter who has used one should not have to learn the
  other. It is a SEPARATE action rather than extra proposals inside the
  rating refresh: the two answer different questions ("are these ratings
  current?" vs "has anyone changed club?"), they are wanted at different
  moments, and merging them would mean an arbiter who only wanted clubs
  had to accept rating changes too.

  ## What it proposes

  Two fields, from one matched KBSB row:

    * `club` — the club NAME (`club_name` on the KBSB row)
    * `club_number` — the KBSB club id

  Both move together or not at all. A player whose name matches but whose
  number does not (or vice versa) is a club that was renamed or renumbered,
  and taking half of that is how a roster ends up with a name and a number
  that disagree.

  ## Matching, and why it is by two ids

  `player.national_id` first, then `player.fide_id` — the KBSB row carries
  both, so a player registered from the FIDE database (FIDE id, no
  matricule) still resolves. That is worth stating because the obvious
  alternative, the KBSB data platform's REST API, cannot do it:
  `GET /players_national/:national_id` returns the club, but there is no
  by-FIDE-id route, and `GET /players_fide/:fide_id` is the raw
  international rating list, which carries no club or federation membership
  at all. Going through the already-synced local copy covers strictly more
  players than the remote API would, needs no API key, and works offline in
  a playing hall — which is where this button gets pressed.

  ## What it will not do

  It never proposes CLEARING a club. A KBSB row with a blank club is a
  player whose membership lapsed or was never recorded, and the arbiter who
  typed a club into the registration dialog knows something the sync does
  not. Same principle as `RatingRefresh`'s title rule: propose what the
  source asserts, never propose deleting what it merely fails to mention.
  """

  alias PairingsEngine.Kbsb
  alias PairingsEngine.Kbsb.KbsbPlayer
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Player

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
  Looks up every player in `tournament` against the local KBSB copy and
  returns `%{proposals:, checked:, changed:, unmatched:}` — `changed` is the
  number of players with at least one proposed change, `unmatched` the
  number with no KBSB match at all (no ids set, or ids not on the list).
  Writes nothing; pair with `apply/2` to commit.
  """
  @spec dry_run(Tournaments.Tournament.t()) :: summary()
  def dry_run(tournament) do
    results =
      tournament.id
      |> Tournaments.list_players()
      |> Enum.map(&player_proposals/1)

    %{
      proposals: Enum.flat_map(results, & &1.proposals),
      checked: length(results),
      changed: Enum.count(results, &(&1.proposals != [])),
      unmatched: Enum.count(results, &(not &1.matched?))
    }
  end

  defp player_proposals(player) do
    kbsb = kbsb_match(player)

    proposals =
      []
      |> maybe_add(player, :club, player.club, club_name(kbsb))
      |> maybe_add(player, :club_number, player.club_number, club_number(kbsb))

    %{proposals: proposals, matched?: kbsb != nil}
  end

  # National id first — it is the KBSB's own primary key, so it cannot be
  # ambiguous. FIDE id second, and only as a fallback: it is indexed but not
  # unique on the local copy, so `find_by_fide_id/1` takes the first row.
  # That is the right trade for a preview-then-apply action (the arbiter
  # sees the proposed club before it is written) and the wrong one for a
  # silent background write, which is why this stays behind a button.
  defp kbsb_match(%Player{} = player) do
    Kbsb.find_by_national_id(player.national_id) || Kbsb.find_by_fide_id(player.fide_id)
  end

  defp club_name(nil), do: nil
  defp club_name(%KbsbPlayer{club_name: name}) when name in [nil, ""], do: nil
  defp club_name(%KbsbPlayer{club_name: name}), do: name

  defp club_number(nil), do: nil
  defp club_number(%KbsbPlayer{club_number: number}), do: number

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

  `RatingRefresh.apply/2` is byte-for-byte this function, and it would work
  on these structs unchanged — it only ever reads `.player`, `.field` and
  `.new`. It is not called: that would be an undeclared cross-module
  contract holding two features together by accident, and the twelve lines
  are cheaper than the day someone spends finding out.
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
