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
  `PairingsEngine.Federations.BEL.SwarImport`), the KBSB search pre-fills it when a player is
  registered off the list, and an arbiter can type it. A bulk button that
  silently rewrote it afterwards made it look like OpenPairings maintains a
  live national-rating system, which it does not. Clubs are a separate
  gesture with its own button - see `PairingsEngine.Federations.BEL.ClubRefresh`.

  A player with no `fide_id` set (or whose id has no match in the list)
  contributes no proposals and counts as "unmatched" in the summary.

  ## Which list the check uses

  A tournament's ratings are those of the monthly list valid on its start date
  (or, for an event lasting more than 30 days, on the day of the check). The
  local database holds one list, whose month is recorded
  (`PairingsEngine.Fide.list_period/0`). `dry_run/1` therefore compares the
  month it needs (`:required_period`, from the start date) with the month it
  has (`:local_period`) and reports `:list_status`:

    * `:ok` - the same month (a tournament without usable dates uses today):
      proposals are made
    * `:local_older` - the local list predates the one needed; update first
    * `:local_newer` - the local list is a later month than the tournament's
      list; comparing would propose ratings the rules do not use, so nothing
      is proposed
    * `:no_list` - nothing downloaded yet

  Every rating applied also records its source list, month and printed value
  on the player (`fide_rating_source`, `fide_rating_period`,
  `fide_rating_listed`).
  """

  import Ecto.Query, only: [from: 2]

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Fide
  alias PairingsEngine.Fide.FidePlayer

  @derive {Inspect, only: [:field, :old, :new]}
  # `extra` is what else is written together with this change - the rating's
  # source list, month and printed value. `id` names the proposal when the
  # arbiter applies only some of them.
  defstruct [:player, :field, :old, :new, :id, extra: %{}]

  @type t :: %__MODULE__{
          player: Player.t(),
          field: atom(),
          old: term(),
          new: term(),
          id: String.t(),
          extra: map()
        }

  @type list_status :: :ok | :local_older | :local_newer | :no_list

  @type summary :: %{
          proposals: [t()],
          checked: non_neg_integer(),
          changed: non_neg_integer(),
          unmatched: non_neg_integer(),
          list_status: list_status(),
          local_period: String.t() | nil,
          required_period: String.t(),
          reference_date: Date.t()
        }

  @doc """
  Looks up every player in `tournament` against the local FIDE copy and
  returns a summary: `%{proposals:, checked:, changed:, unmatched:}` -
  `changed` is the number of players with at least one proposed change,
  `unmatched` the number with no FIDE-id match at all - plus which list was
  used (see the moduledoc): `:list_status`, `:local_period`,
  `:required_period`, `:reference_date`.
  Writes nothing; pair with `apply/2` to commit.
  """
  @spec dry_run(Tournaments.Tournament.t(), Date.t()) :: summary()
  def dry_run(tournament, today \\ Date.utc_today()) do
    reference = reference_date(tournament, today)
    required = Fide.month_of(reference)
    local = Fide.list_period()
    status = list_status(local, required)
    players = Tournaments.list_players(tournament.id)

    results =
      if status == :ok do
        fides = fide_matches(players)
        Enum.map(players, &player_proposals(&1, tournament.standard, fides, local))
      else
        # Not comparable: the players are counted, nothing is proposed.
        Enum.map(players, fn _ -> %{proposals: [], matched?: false} end)
      end

    %{
      proposals: Enum.flat_map(results, & &1.proposals),
      checked: length(results),
      changed: Enum.count(results, &(&1.proposals != [])),
      unmatched: Enum.count(results, &(not &1.matched?)),
      list_status: status,
      local_period: local,
      required_period: required,
      reference_date: reference
    }
  end

  @doc """
  The date whose list applies: the tournament's start date, or - for an event
  lasting more than 30 days, or one with no usable start date - `today`. Never
  later than `today` (a list that does not exist yet cannot be used).
  """
  def reference_date(tournament, today \\ Date.utc_today()) do
    start = parse_date(Map.get(tournament, :start_date))
    finish = parse_date(Map.get(tournament, :end_date))

    cond do
      start == nil -> today
      finish != nil and Date.diff(finish, start) > 30 -> today
      Date.compare(start, today) == :gt -> today
      true -> start
    end
  end

  defp parse_date(<<date::binary-size(10), _::binary>>) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp list_status(nil, _required), do: :no_list

  defp list_status(local, required) do
    cond do
      local == required -> :ok
      local < required -> :local_older
      true -> :local_newer
    end
  end

  @doc """
  What the automatic check shows without being asked: `%{changed: n,
  local_period: p}` when the local list is the one this tournament uses and at
  least one player's rating differs from it, otherwise `nil` (nothing to say,
  or not comparable).
  """
  def notice(tournament, today \\ Date.utc_today()) do
    # Nothing downloaded: no comparison to make, and no reason to read the
    # roster on every page open.
    if Fide.list_period() == nil do
      nil
    else
      case dry_run(tournament, today) do
        %{list_status: :ok, changed: n} = summary when n > 0 ->
          %{changed: n, local_period: summary.local_period}

        _ ->
          nil
      end
    end
  end

  defp fide_matches(players) do
    players
    |> Enum.map(& &1.fide_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn ids -> Repo.all(from f in FidePlayer, where: f.fide_id in ^ids) end)
    |> Map.new(&{&1.fide_id, &1})
  end

  defp player_proposals(player, standard, fides, local_period) do
    fide = if player.fide_id, do: Map.get(fides, player.fide_id)

    proposals =
      []
      |> maybe_add_rating(player, fide, standard, local_period)
      |> maybe_add_title(player, fide)

    %{proposals: proposals, matched?: fide != nil}
  end

  defp maybe_add_rating(list, player, fide, standard, local_period) do
    case Fide.rating_with_source(fide, standard) do
      {rating, source} ->
        extra = %{
          fide_rating_source: source,
          fide_rating_period: local_period,
          fide_rating_listed: rating
        }

        maybe_add(list, player, :fide_rating, player.fide_rating, rating, extra)

      nil ->
        list
    end
  end

  # Only proposes a title when the FIDE record actually carries one - never
  # proposes clearing a locally-set title just because the FIDE row is blank.
  defp maybe_add_title(list, player, %FidePlayer{title: t}) when t not in [nil, ""],
    do: maybe_add(list, player, :title, player.title, t, %{})

  defp maybe_add_title(list, _player, _fide), do: list

  defp maybe_add(list, _player, _field, old, new, _extra) when old == new, do: list

  defp maybe_add(list, player, field, old, new, extra) do
    list ++
      [
        %__MODULE__{
          player: player,
          field: field,
          old: old,
          new: new,
          id: "#{player.id}:#{field}",
          extra: extra
        }
      ]
  end

  @doc """
  Applies `proposals` (as returned in a `dry_run/1` summary's `:proposals`,
  or any chosen subset of them) to `tournament` in a single transaction, firing
  exactly one `tournament_changed` broadcast (via
  `PairingsEngine.Tournaments.bulk_update_players/2`). Proposals for the
  same player are grouped into a single update. A rating change carries its
  source list, month and printed value with it.
  """
  @spec apply(Tournaments.Tournament.t(), [t()]) :: {:ok, [Player.t()]} | {:error, term()}
  def apply(tournament, proposals) do
    updates =
      proposals
      |> Enum.group_by(& &1.player.id)
      |> Enum.map(fn {_player_id, props} ->
        player = hd(props).player

        attrs =
          Enum.reduce(props, %{}, fn p, acc ->
            acc |> Map.put(p.field, p.new) |> Map.merge(p.extra)
          end)

        {player, attrs}
      end)

    Tournaments.bulk_update_players(tournament.id, updates)
  end

  @doc """
  The proposals of `summary` whose `id` is in `ids` (a list of strings), in
  their original order.
  """
  def select(%{proposals: proposals}, ids) do
    wanted = MapSet.new(ids)
    Enum.filter(proposals, &MapSet.member?(wanted, &1.id))
  end
end
