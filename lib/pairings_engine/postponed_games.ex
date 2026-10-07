defmodule PairingsEngine.PostponedGames do
  @moduledoc """
  Postponed and adjourned games: a board whose game was paired and has not
  been played yet (VCL4THP Q157-169, `docs/design-fide-mode.md` Phase 5).

  ## What a postponed game is

  In club play a game is often not played in its round - moved by agreement
  to a later evening, or adjourned - while the tournament goes on. The board
  carries `PairingsEngine.Results.postponed/0` (`"*"`): result unknown, game
  still to be played. It is not a blank. A blank is a board nobody has
  reported on and stops the next round from being paired; `"*"` is the
  arbiter saying "this one is known to be open".

  What it is worth is decided in exactly one place, the `PairingsEngine.Results`
  table, which classifies it as a draw for both players. So the crosstable,
  the tie-breaks, the pairing engine's score brackets and every export read
  the same half point, and there is no second result-to-points mapping to
  drift from the first (the shape that caused three bugs before 0.17.1).
  When the real result is entered, everything recomputes from it.

  ## What this module adds

    * which games are open (`open_games/1`), for the pages that list them
      and for anything that must not call itself final while one is;
    * the warnings, as codes (`warnings/0`). Sentences live in the web layer
      (`PairingsEngineWeb.PostponedText`), the same split
      `PairingsEngine.Compliance` keeps, so a warning can be translated and
      so a FIDE warning level can be attached to each entry later without
      touching what fires it;
    * the checks the two write paths ask before they act:
      `pairing_warnings/1` before a round is paired, `result_warnings/2`
      before a result is written over a postponed game.

  ## The warnings and their levels

  VCL4THP asks for some of these at a "Level 2" or "Level 3". The levels are
  not defined anywhere this project can read yet (`docs/design-fide-mode.md`,
  Phase 0 and Phase 4), so none is guessed here: every warning is an ordinary
  confirmation or notice, identified by an id naming its VCL question. When
  the levels exist they become one more key per entry of `@warnings`.
  """

  import Ecto.Query
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.{Repo, Results, SentReceipts}
  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament, TrfSentGame}

  # One entry per warning. `vcl` is the VCL4THP v13 question it answers;
  # `acknowledge?` is whether the action it guards waits for the arbiter to
  # confirm it (the write path refuses with `{:needs_acknowledgement, ids}`
  # until they have), as opposed to a notice shown beside the action.
  @warnings [
    %{id: :adjourned_non_draw_result, vcl: [163], acknowledge?: true},
    %{id: :missing_results_recorded_as_adjourned, vcl: [159, 160], acknowledge?: true},
    %{id: :adjourned_older_round_open, vcl: [168], acknowledge?: true},
    %{id: :adjourned_counted_as_draw, vcl: [158, 167], acknowledge?: false},
    %{id: :adjourned_standings_not_final, vcl: [161, 169], acknowledge?: false},
    %{id: :adjourned_trf_not_final, vcl: [164, 165, 169], acknowledge?: false},
    # Not a VCL question: a result that already went to the federation in a
    # TRF marked as sent (see `finalise/2`). The rule above every other one
    # here is that no wrong TRF data is ever sent, so changing a sent
    # result is possible - "semi-frozen" - but never silent.
    %{id: :finalised_result_changed, vcl: [], acknowledge?: true},
    # A result corrected after a later round was paired - the TEC Manual's
    # Correction PIBE, a Level-3 warning with explicit confirmation
    # (`PairingsEngine.ResultCorrections`).
    %{id: :result_correction, vcl: [112, 115], acknowledge?: true},
    %{id: :sent_round_changed, vcl: [], acknowledge?: true},
    %{id: :sent_games_changed, vcl: [], acknowledge?: true},
    # A round sent before, then taken back to before it was paired by a
    # restore and paired again with other games: sending it again reports
    # its number a second time (`PostponedGames.sent_before_rounds/1`).
    %{id: :round_sent_before, vcl: [], acknowledge?: true},
    # Two players with no FIDE ID and the same name are one key in the
    # sent-games record (`player_key/1`), so it cannot tell their games
    # apart. Shown beside sending and after a restore; it blocks nothing.
    %{id: :sent_games_ambiguous_players, vcl: [], acknowledge?: false}
  ]

  @doc "Every warning this feature can raise, with the VCL question it answers."
  def warnings, do: @warnings

  @doc "The ids of the warnings an action waits on the arbiter to confirm."
  def acknowledgement_ids do
    for %{acknowledge?: true, id: id} <- @warnings, do: id
  end

  @doc """
  Every open postponed game in `tournament`, oldest round first, as
  `%{round: n, pairing: %Pairing{}}` with both players preloaded.
  """
  def open_games(%Tournament{id: id}), do: open_games(id)

  def open_games(tournament_id) when is_integer(tournament_id) do
    postponed = Results.postponed_codes()

    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.result in ^postponed,
        order_by: [r.number, p.board],
        preload: [:white_player, :black_player],
        select: %{round: r.number, pairing: p}
    )
  end

  @doc "How many postponed games are still open in `tournament`."
  def open_count(%Tournament{id: id}), do: open_count(id)

  def open_count(tournament_id) when is_integer(tournament_id) do
    postponed = Results.postponed_codes()

    Repo.aggregate(
      from(p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.result in ^postponed
      ),
      :count
    )
  end

  @doc """
  How many postponed games are open in each of `tournament_ids`, as
  `%{tournament_id => count}` - one query for a list of tournaments. A
  tournament with none is absent from the map.
  """
  def open_counts([]), do: %{}

  def open_counts(tournament_ids) when is_list(tournament_ids) do
    postponed = Results.postponed_codes()

    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id in ^tournament_ids and p.result in ^postponed,
        group_by: r.tournament_id,
        select: {r.tournament_id, count(p.id)}
    )
    |> Map.new()
  end

  @doc """
  How many open postponed games each player still has, as
  `%{player_id => count}`, from `open_games/1`'s answer - what the standings
  mark beside a name ("1 pending"), so a provisional place is not read as a
  final one. A player with none is absent from the map.
  """
  def pending_by_player(open_games) do
    open_games
    |> Enum.flat_map(fn %{pairing: p} ->
      Enum.reject([p.white_player_id, p.black_player_id], &is_nil/1)
    end)
    |> Enum.frequencies()
  end

  @doc """
  The FIDE rating period a game played on `date` falls in, and the date to
  have it reported by, as `%{period: first day of the month, deadline: last
  day of the month}`.

  FIDE rates month by month, so this is the calendar month the game was
  played in, and the end of that month is used as the date to have it sent
  by. It is guidance for the organiser, not a rule this app enforces - a
  federation may set its own, earlier, cut-off.
  """
  def rating_period(%Date{} = date) do
    %{period: Date.beginning_of_month(date), deadline: Date.end_of_month(date)}
  end

  @doc """
  The rating period of a late game (`%{pairing: %Pairing{}}` or a pairing):
  the first day of the month it was played in, nil when no date is known.
  The postponed-games file carries one period only.
  """
  def late_period(%{pairing: %Pairing{} = pairing}), do: late_period(pairing)
  def late_period(%Pairing{played_on: %Date{} = date}), do: rating_period(date).period
  def late_period(%Pairing{}), do: nil

  @doc """
  The name the postponed-games file is reported under - a tournament of its
  own (`PairingsEngine.TrfExport.postponed_export/2`): the arbiter's
  (`postponed_report_name`), or the event's name followed by "postponed
  games" in the language of the page ("uitgestelde partijen" in Dutch).
  """
  def report_name(%Tournament{postponed_report_name: name} = tournament) do
    case name && String.trim(name) do
      value when is_binary(value) and value != "" -> value
      _ -> default_report_name(tournament)
    end
  end

  @doc "The default for `report_name/1`."
  def default_report_name(%Tournament{name: name}),
    do: gettext("%{name} postponed games", name: name)

  @doc """
  Whether anything computed from `tournament`'s results may call itself
  final: `false` while a postponed game is open, whatever round it is in.
  """
  def final?(tournament), do: open_count(tournament) == 0

  @doc """
  The warnings that apply to pairing `tournament`'s next round, as
  `%{id: atom, ...details}` maps.

    * `:missing_results_recorded_as_adjourned` - the last paired round
      still has boards with two players and no result. Pairing records them
      as postponed first (Q159) once the arbiter has confirmed it (Q160).
      Offered only when that would complete the round: a vacated seat has
      no second player to postpone a game with, and still has to be
      resolved on the board first.
    * `:adjourned_older_round_open` - a postponed game from a round before
      the last paired one is still open (Q168).
    * `:adjourned_counted_as_draw` - a postponed game in the last paired
      round; a notice that it counts as a draw for this pairing (Q158, Q167).

  Empty for a round robin, whose schedule does not depend on results, and
  before round 1. `open` is `open_games/1`'s answer when the caller already
  has it (the Pairings page lists the same games), so it is not asked twice.
  """
  def pairing_warnings(tournament, open \\ nil)

  def pairing_warnings(%Tournament{pairing_system: "round_robin"}, _open), do: []

  def pairing_warnings(%Tournament{} = tournament, open) do
    last = last_paired_round(tournament.id)

    cond do
      last == 0 ->
        []

      # Recording a board as postponed is only offered where postponed games
      # are allowed at all; elsewhere a blank still simply blocks pairing.
      not tournament.postponed_games ->
        open_warnings(open || open_games(tournament.id), last)

      true ->
        missing_warning(tournament.id, last) ++
          open_warnings(open || open_games(tournament.id), last)
    end
  end

  defp missing_warning(tournament_id, last) do
    blanks =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament_id and r.number == ^last and p.result == "",
          select: {p.white_player_id, p.black_player_id}
      )

    cond do
      blanks == [] -> []
      Enum.any?(blanks, fn {w, b} -> is_nil(w) or is_nil(b) end) -> []
      true -> [%{id: :missing_results_recorded_as_adjourned, round: last, count: length(blanks)}]
    end
  end

  defp open_warnings(open, last) do
    {older, current} = Enum.split_with(open, &(&1.round < last))

    older_warning =
      if older == [],
        do: [],
        else: [
          %{
            id: :adjourned_older_round_open,
            rounds: older |> Enum.map(& &1.round) |> Enum.uniq(),
            count: length(older)
          }
        ]

    current_warning =
      if current == [],
        do: [],
        else: [%{id: :adjourned_counted_as_draw, round: last, count: length(current)}]

    older_warning ++ current_warning
  end

  defp last_paired_round(tournament_id) do
    Repo.one(from r in Round, where: r.tournament_id == ^tournament_id, select: max(r.number)) ||
      0
  end

  @doc """
  The warnings that apply to writing `result` over the board as it is
  STORED now - read fresh, because the struct a page holds can be older
  than the database, and a stale blank must not hide a postponed game.

  `:adjourned_non_draw_result` (Q163), when a postponed game gets a result
  that is not a draw for both players. Every round paired since counted it
  as its provisional score, and those pairings stand; the arbiter confirms
  that they know. A draw, clearing the board and re-postponing it need no
  confirmation.

  `:result_correction` (Q112, Q115), when a real result is corrected after
  a later round was paired - a Correction PIBE
  (`PairingsEngine.ResultCorrections.correction?/2`).

  `:finalised_result_changed`, when the board was already sent in a TRF
  marked as sent and the result would change: possible, never silent.
  """
  def result_warnings(%Pairing{id: id}, result) do
    stored = Repo.get!(Pairing, id)

    non_draw? =
      Results.postponed?(stored.result) and result not in ["", nil] and
        not Results.postponed?(result) and not Results.draw_for_both?(result)

    # A board already sent in a finalised TRF, with the result it was sent
    # with. An open postponed game sent as `?` is the exception: its real
    # result is still to come, and goes in the postponed-games file - after
    # which it is sent too.
    sent_changed? =
      result != stored.result and
        ((not is_nil(stored.finalised_at) and not stored.finalised_open) or
           not is_nil(stored.postponed_reported_at))

    correction? = PairingsEngine.ResultCorrections.correction?(stored, result)

    if(non_draw?, do: [:adjourned_non_draw_result], else: []) ++
      if(sent_changed?, do: [:finalised_result_changed], else: []) ++
      if correction?, do: [:result_correction], else: []
  end

  @doc """
  `:ok` when every warning in `warnings` (ids or `%{id: ...}` maps) that
  waits on the arbiter is in `acknowledged`, otherwise
  `{:error, {:needs_acknowledgement, ids}}` naming the ones that are not.
  Notices are never waited on.
  """
  def check_acknowledged(warnings, acknowledged) do
    missing =
      warnings
      |> Enum.map(&warning_id/1)
      |> Enum.filter(&(&1 in acknowledgement_ids()))
      |> Enum.reject(&(&1 in acknowledged))
      |> Enum.uniq()

    if missing == [], do: :ok, else: {:error, {:needs_acknowledgement, missing}}
  end

  defp warning_id(%{id: id}), do: id
  defp warning_id(id) when is_atom(id), do: id

  @doc """
  Records every two-player board of `round_number` that has no result as a
  postponed game (Q159), through `Tournaments.update_pairing_result/3` like
  every other result write. Returns `{:ok, pairing_ids}` - the boards it
  wrote, so a pairing run that then fails can put them back with
  `clear/1` - or the first write's error.
  """
  def record_missing(%Tournament{} = tournament, round_number) do
    blanks =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where:
            r.tournament_id == ^tournament.id and r.number == ^round_number and p.result == "" and
              not is_nil(p.white_player_id) and not is_nil(p.black_player_id)
      )

    Enum.reduce_while(blanks, {:ok, []}, fn pairing, {:ok, ids} ->
      case PairingsEngine.Tournaments.update_pairing_result(pairing, Results.postponed()) do
        {:ok, _} -> {:cont, {:ok, [pairing.id | ids]}}
        {:error, reason} -> {:halt, {:error, reason, ids}}
      end
    end)
    |> case do
      {:ok, ids} ->
        {:ok, Enum.reverse(ids)}

      # One write refused (a locked database, a hand-off landing mid-run):
      # the boards already recorded go back too, so a refusal leaves the
      # round exactly as the arbiter left it.
      {:error, reason, ids} ->
        clear(ids)
        {:error, reason}
    end
  end

  @doc """
  Puts boards `record_missing/2` postponed back to no result - the undo for
  a pairing run that failed after the missing results were recorded, so a
  refused round leaves the tournament exactly as it found it.
  """
  def clear(pairing_ids) do
    for pairing <- Repo.all(from p in Pairing, where: p.id in ^pairing_ids),
        Results.postponed?(pairing.result),
        is_nil(pairing.finalised_at) do
      PairingsEngine.Tournaments.update_pairing_result(pairing, "")
    end

    :ok
  end

  ## ---------- sending results: finalise, and the postponed-games file ----------
  #
  # The rule above every other one here: no wrong TRF data is ever sent, and
  # no game is sent twice. Two kinds of record make that checkable rather
  # than a matter of care.
  #
  # On the board (`pairings`), for the pages and the exports to read:
  #
  #   * `finalised_at` - the board went into a TRF the arbiter downloaded "for
  #     sending". Its result is then semi-frozen: changing it asks first
  #     (`:finalised_result_changed`), and so does moving a player in or out
  #     of its round (`:sent_round_changed`).
  #   * `finalised_open` - it was an open postponed game at that moment, so
  #     it went out unplayed - recorded as `?`, written in the file for
  #     rating as not played (`0000 - Z`, `TrfExport.export/3`'s
  #     `for: :rating`; as `?` itself before that). Every later main report
  #     writes it the same way again, so a file already sent never changes
  #     and the game is never rated there; its real result, once played,
  #     goes in the postponed-games file (`sendable_late_games/1`), and
  #     `postponed_reported_at` records that it has been sent there - once.
  #
  # And the sent-games record (`TrfSentGame`, one row per game per file),
  # which is what those marks are rebuilt from. The marks are tournament
  # contents, and a snapshot restore or a hand-off return replaces contents
  # wholesale; the record is kept beside the audit trail, which neither
  # touches. So rolling a tournament back to before a round was sent cannot
  # make that round sendable again: `finalise/3` asks the record, and
  # `reapply_sent_marks/1` puts the marks back on every game still there.
  #
  # ## Which game a record is about
  #
  # A record names its game by the board's `game_uid` - an identity the
  # board keeps for life, carried by every export, snapshot and hand-off and
  # written back by a restore - and, for a record older than that identity
  # or whose game is no longer in the tournament, by round and players
  # (`player_key/1`). The identity is asked first: a FIDE ID filled in or a
  # name corrected between a snapshot and a restore no longer makes a sent
  # game look unsent, or an open one lose its `?` (audit 2026-10-01, F4).
  # Matching by players stays as the fallback because it errs the safe way:
  # a re-paired board identical to a game already sent (same round, same
  # players, same colours) IS that game, and is refused a second time.
  #
  # ## Two sends at once
  #
  # Checking "already sent?" and then writing is two steps, and two requests
  # (a double click, a second tab, a co-arbiter) can both pass the check
  # before either writes. So each send re-checks inside one write
  # transaction (`BEGIN IMMEDIATE` - SQLite's writer lock is taken before
  # the first read), and the record's unique index (one `"sent"` record per
  # game per kind of file) refuses the second insert even if a check were
  # ever wrong. The loser gets `{:error, {:already_sent, _}}`, never a file:
  # the file is built inside the same transaction (`send_rounds/4`,
  # `send_late_games/2`), so it exists only for the request whose record
  # landed (audit F1, F2).

  @doc """
  Who a sent game's player is, as the TRF names them: `"fide:<id>"`, or
  `"name:<name>"`, trimmed and lower-cased, for a player with no FIDE ID.
  nil for an empty seat. The sent-games record's fallback identity for a
  game - see the section above.
  """
  def player_key(nil), do: nil
  def player_key(%{fide_id: id}) when is_integer(id) and id > 0, do: "fide:#{id}"

  def player_key(%{name: name}),
    do: "name:" <> (name |> to_string() |> String.trim() |> String.downcase())

  @doc """
  The players of tournament `tournament_id` the sent-games record cannot
  tell apart by name (`:sent_games_ambiguous_players`): two or more with no
  FIDE ID whose names are the same once `player_key/1` has trimmed and
  lower-cased them. One `%{key:, names:, count:}` per such name, `names` the
  spellings as entered (trimmed, sorted). Empty when every player has a key
  of their own.

  Since every game carries its own identity this only matters for records
  older than that identity, and for games no longer in the tournament.
  """
  def ambiguous_players(tournament_id) when is_integer(tournament_id) do
    Repo.all(
      from p in PairingsEngine.Tournaments.Player,
        where: p.tournament_id == ^tournament_id,
        select: %{fide_id: p.fide_id, name: p.name}
    )
    |> Enum.group_by(&player_key/1)
    |> Enum.filter(fn {key, players} ->
      String.starts_with?(key, "name:") and length(players) > 1
    end)
    |> Enum.map(fn {key, players} ->
      names =
        players
        |> Enum.map(&(&1.name |> to_string() |> String.trim()))
        |> Enum.uniq()
        |> Enum.sort()

      %{key: key, names: names, count: length(players)}
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  The ambiguous players (`ambiguous_players/1`) who have a game in the
  sent-games record that is matched by players - the ones whose sent games a
  restore or a hand-off return may put back on the wrong board.
  """
  def ambiguous_sent_players(tournament_id) when is_integer(tournament_id) do
    case ambiguous_players(tournament_id) do
      [] ->
        []

      ambiguous ->
        keys =
          Repo.all(
            from s in TrfSentGame,
              where: s.tournament_id == ^tournament_id,
              select: [s.white_key, s.black_key]
          )
          |> List.flatten()
          |> MapSet.new()

        Enum.filter(ambiguous, &MapSet.member?(keys, &1.key))
    end
  end

  ## ---------- the record, matched to the boards ----------

  # Every board of the tournament, `{round, %Pairing{}}` with both players.
  defp boards(tournament_id) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id,
        order_by: [r.number, p.board],
        preload: [:white_player, :black_player],
        select: {r.number, p}
    )
  end

  defp records(tournament_id) do
    Repo.all(
      from s in TrfSentGame,
        where: s.tournament_id == ^tournament_id,
        order_by: [s.sent_at, s.id]
    )
  end

  # Matches each record to the boards it is about. `boards` are plain maps
  # `%{ref:, round:, game_uid:, white_key:, black_key:}` so a snapshot's
  # payload can be matched the same way as the live tournament. Returns
  # `{%{ref => [record]}, unmatched_records}`.
  #
  # By identity first; by round and players when the record has none, or its
  # game is not among `boards` (see the section above).
  defp match_records(records, boards) do
    by_uid = for b <- boards, b.game_uid, into: %{}, do: {b.game_uid, b.ref}

    by_key =
      Enum.group_by(boards, &{&1.round, &1.white_key, &1.black_key}, & &1.ref)

    Enum.reduce(records, {%{}, []}, fn record, {matched, unmatched} ->
      refs =
        case record.game_uid && Map.fetch(by_uid, record.game_uid) do
          {:ok, ref} -> [ref]
          _ -> Map.get(by_key, {record.round, record.white_key, record.black_key}, [])
        end

      case refs do
        [] ->
          {matched, [record | unmatched]}

        refs ->
          {Enum.reduce(refs, matched, fn ref, acc ->
             Map.update(acc, ref, [record], &(&1 ++ [record]))
           end), unmatched}
      end
    end)
    |> then(fn {matched, unmatched} -> {matched, Enum.reverse(unmatched)} end)
  end

  defp board_ref({round, %Pairing{} = p}) do
    %{
      ref: p.id,
      round: round,
      game_uid: p.game_uid,
      white_key: player_key(p.white_player),
      black_key: player_key(p.black_player)
    }
  end

  # `{boards, %{pairing_id => [record]}, unmatched}` for the live tournament.
  defp sent_index(tournament_id) do
    boards = boards(tournament_id)
    {matched, unmatched} = match_records(records(tournament_id), Enum.map(boards, &board_ref/1))
    {boards, matched, unmatched}
  end

  defp report_records(matched, %Pairing{id: id}),
    do: matched |> Map.get(id, []) |> Enum.filter(&(&1.kind == "report"))

  defp late_records(matched, %Pairing{id: id}),
    do: matched |> Map.get(id, []) |> Enum.filter(&(&1.kind == "postponed"))

  defp sent_in_report?(matched, %Pairing{} = p),
    do: not is_nil(p.finalised_at) or report_records(matched, p) != []

  defp sent_rounds_of({boards, matched, _unmatched}) do
    boards
    |> Enum.filter(fn {_round, p} -> sent_in_report?(matched, p) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Rounds the record says were sent in a report, none of whose games are
  # in the tournament now: it went back to before the round was paired (a
  # restore), and the round was - or may be - paired again with other games.
  defp sent_before_rounds_of({_boards, _matched, unmatched} = index) do
    sent = sent_rounds_of(index)

    unmatched
    |> Enum.filter(&(&1.kind == "report"))
    |> Enum.map(& &1.round)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in sent))
    |> Enum.sort()
  end

  @doc """
  The numbers of the rounds of `tournament` already sent in a report, in
  order - the ones `finalise/3` refuses a second time: every round with a
  board that carries a sent mark or is in the sent-games record. From the
  record and the marks both, so neither alone can lose one.

  A round sent and then taken away by a restore to before it was paired is
  not in this list once it holds only other games (`sent_before_rounds/1`):
  those games were never sent, and refusing them forever would leave them
  unreportable. A board identical to a sent game (same round, players,
  colours) still counts as that game, and keeps its round sent.
  """
  def sent_rounds(%Tournament{id: id}), do: id |> sent_index() |> sent_rounds_of()

  @doc """
  Rounds sent in a report whose games are all gone from the tournament (a
  restore to before the round was paired), and which are not sent with the
  games they hold now. Sending such a round again reports its number a
  second time with other games, so `finalise/3` waits for
  `:round_sent_before` to be acknowledged.
  """
  def sent_before_rounds(%Tournament{id: id}), do: id |> sent_index() |> sent_before_rounds_of()

  @doc """
  Whether round `number` of tournament `tournament_id` was sent in a report
  (`sent_rounds/1`).
  """
  def round_sent?(tournament_id, number) do
    number in (tournament_id |> sent_index() |> sent_rounds_of())
  end

  ## ---------- sending a round ----------

  @doc """
  Marks every board of `rounds` as sent (see the section above) and records
  each game in the sent-games record - `send_rounds/4` without a file.
  Returns `{:ok, newly_marked}` or `send_rounds/4`'s errors.
  """
  def finalise(%Tournament{} = tournament, rounds, opts \\ []) when is_list(rounds) do
    with {:ok, %{marked: marked}} <- send_rounds(tournament, rounds, nil, opts), do: {:ok, marked}
  end

  @doc """
  Sends `rounds` of `tournament`: builds the file with `build` (a function
  of the fresh tournament returning `{:ok, text}` or `{:error, _}`; nil for
  none), marks every board as sent and records each game - all in one write
  transaction, so the file exists only if the record landed and the record
  lands only if the file was built. Then the send's receipts are recorded,
  one per round (`PairingsEngine.SentReceipts`); the file is returned as
  built, with no line added. Returns
  `{:ok, %{marked: n, file: text, receipts: [%SentReceipt{}]}}`. `opts` may
  name who sends (`sent_by:` a label, `sent_by_id:`) for the receipt.

  Refused, writing nothing and building nothing:

    * `{:error, :handed_off}` / `{:error, :archived}` - this copy is locked
      (`Tournaments.ensure_writable/1`); a copy handed to another machine
      must not report what that machine is now reporting (audit F3);
    * `{:error, {:already_sent, rounds}}` - one of those rounds was already
      sent (`sent_rounds/1`); a second file with its games would send them
      twice. Also every requested round of a copy imported from a file of
      an event that may have been reported elsewhere, until an arbiter
      confirms it is the copy that reports (`Tournament.send_confirmation_needed`,
      audit F5) - for all this copy knows, they were;
    * `{:error, {:blank_results, rounds}}` - a board has no result at all;
      a file for sending must not carry a gap nobody decided about;
    * `{:error, {:needs_acknowledgement, [:round_sent_before]}}` - a round
      was sent before with games no longer in the tournament
      (`sent_before_rounds/1`); `acknowledged: [:round_sent_before]` in
      `opts` sends it anyway;
    * `build`'s own error.

  Downloading without sending is always possible, to see or keep a copy.
  """
  def send_rounds(%Tournament{} = tournament, rounds, build, opts \\ []) when is_list(rounds) do
    acknowledged = Keyword.get(opts, :acknowledged, [])

    # Checked first outside the transaction, for a quick answer, then again
    # inside it - only the second one decides anything.
    with :ok <- round_send_check(tournament.id, rounds, acknowledged) do
      Repo.transaction(
        fn ->
          fresh = Repo.get!(Tournament, tournament.id)

          with :ok <- PairingsEngine.Tournaments.ensure_writable(fresh),
               :ok <- confirmed_copy(fresh, rounds),
               :ok <- round_send_check(fresh.id, rounds, acknowledged),
               {:ok, file} <- build_file(build, fresh),
               {:ok, marked} <- record_round_send(fresh.id, rounds),
               # The receipt, once the record landed: what went out
               # (`SentReceipts`). It decides nothing about whether the
               # send may happen, and adds nothing to the file.
               {:ok, receipts, file} <-
                 SentReceipts.record_rounds(fresh.id, rounds, file, receipt_opts(opts)) do
            %{marked: marked, file: file, receipts: receipts}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        mode: :immediate
      )
    end
  end

  # Who sent it, for the receipt (`SentReceipts.record_rounds/4`).
  defp receipt_opts(opts), do: Keyword.take(opts, [:sent_by, :sent_by_id])

  defp build_file(nil, _tournament), do: {:ok, nil}

  defp build_file(build, tournament) do
    case build.(tournament) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirmed_copy(%Tournament{send_confirmation_needed: nil}, _rounds), do: :ok
  defp confirmed_copy(%Tournament{}, rounds), do: {:error, {:already_sent, Enum.sort(rounds)}}

  defp round_send_check(tournament_id, rounds, acknowledged) do
    index = sent_index(tournament_id)
    already = index |> sent_rounds_of() |> Enum.filter(&(&1 in rounds))
    before = index |> sent_before_rounds_of() |> Enum.filter(&(&1 in rounds))

    blank_rounds =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament_id and r.number in ^rounds and p.result == "",
          distinct: true,
          select: r.number
      )

    cond do
      already != [] -> {:error, {:already_sent, already}}
      blank_rounds != [] -> {:error, {:blank_results, Enum.sort(blank_rounds)}}
      before != [] -> check_acknowledged([:round_sent_before], acknowledged)
      true -> :ok
    end
  end

  defp record_round_send(tournament_id, rounds) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    boards =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where:
            r.tournament_id == ^tournament_id and r.number in ^rounds and
              is_nil(p.finalised_at),
          preload: [:white_player, :black_player],
          select: {r.number, p}
      )

    # Compared here, not in SQL: SQLite hands a boolean back as 0 or 1.
    {open, known} = Enum.split_with(boards, fn {_, p} -> Results.postponed?(p.result) end)

    games =
      for({round, p} <- open, do: {round, p, "?"}) ++
        for({round, p} <- known, do: {round, p, p.result})

    case record_sent(tournament_id, games, "report", now) do
      :ok ->
        mark(Enum.map(open, &elem(&1, 1).id), finalised_at: now, finalised_open: true)
        mark(Enum.map(known, &elem(&1, 1).id), finalised_at: now, finalised_open: false)
        {:ok, length(boards)}

      {:error, :already_sent} ->
        {:error, {:already_sent, Enum.sort(rounds)}}
    end
  end

  defp mark([], _set), do: :ok

  defp mark(ids, set) do
    Repo.update_all(from(p in Pairing, where: p.id in ^ids), set: set)
    :ok
  end

  # Writes one record per game. `"sent"` records go through the unique
  # index: a game already recorded as sent in that kind of file is not
  # inserted again, and the whole send is refused (`{:error, :already_sent}`).
  defp record_sent(tournament_id, games, kind, now, origin \\ "sent")

  defp record_sent(_tournament_id, [], _kind, _now, _origin), do: :ok

  defp record_sent(tournament_id, games, kind, now, origin) do
    rows =
      for {round, pairing, sent_as} <- games do
        %{
          tournament_id: tournament_id,
          round: round,
          white_key: player_key(pairing.white_player),
          black_key: player_key(pairing.black_player),
          game_uid: pairing.game_uid,
          kind: kind,
          origin: origin,
          sent_as: sent_as,
          sent_at: now
        }
      end

    {inserted, _} = Repo.insert_all(TrfSentGame, rows, on_conflict: :nothing)

    if inserted == length(rows), do: :ok, else: {:error, :already_sent}
  end

  @doc """
  Where each paired round of `tournament` stands for the TRF report, in
  round order - what Settings, Export shows one row per round:

      %{round: n, boards: count, missing: boards without a result,
        postponed: open postponed games, sent_at: DateTime | nil,
        sent_before: boolean, state: :sent | :ready | :playing}

  `:sent` is `sent_rounds/1`'s answer (`sent_at` is the latest time the
  record has, nil for a round known sent only from the marks on its boards);
  `:playing` a round with a board still without a result, which `finalise/3`
  refuses; `:ready` the rest, an open postponed game included - it goes out
  as unknown and its result follows in the postponed-games file.
  `sent_before` marks a round sent earlier with games it no longer holds
  (`sent_before_rounds/1`).
  """
  def trf_round_states(%Tournament{id: id} = tournament) do
    counts =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^id,
          group_by: r.number,
          order_by: r.number,
          select:
            {r.number, count(p.id), sum(fragment("CASE WHEN ? = '' THEN 1 ELSE 0 END", p.result))}
      )

    postponed = tournament |> open_games() |> Enum.frequencies_by(& &1.round)
    index = sent_index(id)
    sent = MapSet.new(sent_rounds_of(index))
    before = MapSet.new(sent_before_rounds_of(index))

    sent_at =
      index
      |> elem(1)
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(&1.kind == "report"))
      |> Enum.group_by(& &1.round, & &1.sent_at)
      |> Map.new(fn {round, ats} -> {round, Enum.max(ats, DateTime)} end)

    for {n, boards, missing} <- counts do
      missing = missing || 0

      state =
        cond do
          MapSet.member?(sent, n) -> :sent
          missing > 0 -> :playing
          true -> :ready
        end

      %{
        round: n,
        boards: boards,
        missing: missing,
        postponed: Map.get(postponed, n, 0),
        sent_at: Map.get(sent_at, n),
        sent_before: MapSet.member?(before, n),
        state: state
      }
    end
  end

  ## ---------- after the contents were replaced ----------

  @doc """
  After a restore, a hand-off return or an import replaced the tournament's
  contents: puts the sent marks back on every board the sent-games record
  knows, and records any mark the new contents carry that the record does
  not hold (a round sent on the other machine during a hand-off).

  A board's marks follow its records: sent in a report when one names it;
  sent as `?` (`finalised_open`, its late result still to go in the
  postponed-games file) only while every report that carried it carried
  `?`. A game whose real result went out in any report - the other copy
  sent it with its result while this one sent `?` - is never offered for
  the postponed-games file: that would be its third send (audit F3).

  Run inside the replacing transaction, after the contents are written.
  """
  def reapply_sent_marks(tournament_id) do
    {boards, matched, _unmatched} = sent_index(tournament_id)

    for {round, p} <- boards do
      reports = report_records(matched, p)
      lates = late_records(matched, p)

      recorded = unrecorded_marks(tournament_id, round, p, reports, lates)
      reports = reports ++ Enum.filter(recorded, &(&1.kind == "report"))
      lates = lates ++ Enum.filter(recorded, &(&1.kind == "postponed"))

      changes =
        Enum.reject(
          [
            reports != [] &&
              {:finalised_at,
               p.finalised_at || Enum.min(Enum.map(reports, & &1.sent_at), DateTime)},
            reports != [] && {:finalised_open, Enum.all?(reports, &(&1.sent_as == "?"))},
            lates != [] &&
              {:postponed_reported_at,
               p.postponed_reported_at || Enum.min(Enum.map(lates, & &1.sent_at), DateTime)}
          ],
          &(&1 == false)
        )
        |> Enum.reject(fn {field, value} -> Map.get(p, field) == value end)

      if changes != [],
        do: Repo.update_all(from(x in Pairing, where: x.id == ^p.id), set: changes)
    end

    :ok
  end

  # Marks that came in with the contents and are not on record: a round
  # sent on the other machine while the tournament was handed off. Recorded
  # as a send another copy made (`origin: "copy"`), outside the one-send
  # guard - it already happened, and both facts are kept. Returns the
  # records written.
  defp unrecorded_marks(tournament_id, round, p, reports, lates) do
    report_mark =
      cond do
        is_nil(p.finalised_at) -> []
        # This copy says it went out as `?`; the record has no `?` send.
        p.finalised_open and not Enum.any?(reports, &(&1.sent_as == "?")) -> ["?"]
        # This copy says it went out with its result; the record has none.
        not p.finalised_open and Enum.all?(reports, &(&1.sent_as == "?")) -> [p.result]
        true -> []
      end

    late_mark =
      if lates == [] and not is_nil(p.postponed_reported_at), do: [p.result], else: []

    (for(sent_as <- report_mark, do: {"report", sent_as, p.finalised_at}) ++
       for(sent_as <- late_mark, do: {"postponed", sent_as, p.postponed_reported_at}))
    |> Enum.map(fn {kind, sent_as, at} ->
      at = DateTime.truncate(at, :second)
      :ok = record_sent(tournament_id, [{round, p, sent_as}], kind, at, "copy")
      %{kind: kind, sent_as: sent_as, sent_at: at}
    end)
  end

  @doc """
  The sent-games record of `tournament_id` as plain maps, for an export
  file (`PairingsEngine.TournamentExport`): a copy of the tournament made
  from that file then knows what this one sent.
  """
  def export_records(tournament_id) do
    for s <- records(tournament_id) do
      %{
        "round" => s.round,
        "white_key" => s.white_key,
        "black_key" => s.black_key,
        "game_uid" => s.game_uid,
        "kind" => s.kind,
        "sent_as" => s.sent_as,
        "sent_at" => DateTime.to_iso8601(s.sent_at),
        "origin" => s.origin
      }
    end
  end

  @doc """
  Adds the records an export file carries (`export_records/1`) to
  `tournament_id`'s record, as sends another copy made (`origin`, default
  `"import"`). A record already held (same game, kind, result and time) is
  not added twice; a malformed entry is skipped. Nothing is ever removed.
  Run before `reapply_sent_marks/1`, inside the importing transaction.
  """
  def merge_records(tournament_id, entries, origin \\ "import") when is_list(entries) do
    held =
      tournament_id
      |> records()
      |> MapSet.new(
        &{&1.kind, &1.game_uid, &1.round, &1.white_key, &1.black_key, &1.sent_as, &1.sent_at}
      )

    rows =
      for %{} = e <- entries,
          {:ok, at, _} <- [DateTime.from_iso8601(to_string(e["sent_at"]))],
          is_integer(e["round"]) and e["kind"] in ~w(report postponed) and
            is_binary(e["sent_as"]),
          at <- [DateTime.truncate(at, :second)],
          row <- [
            %{
              tournament_id: tournament_id,
              round: e["round"],
              white_key: string_or_nil(e["white_key"]),
              black_key: string_or_nil(e["black_key"]),
              game_uid: string_or_nil(e["game_uid"]),
              kind: e["kind"],
              origin: origin,
              sent_as: e["sent_as"],
              sent_at: at
            }
          ],
          not MapSet.member?(
            held,
            {row.kind, row.game_uid, row.round, row.white_key, row.black_key, row.sent_as, at}
          ),
          uniq: true,
          do: row

    if rows != [], do: Repo.insert_all(TrfSentGame, rows)
    :ok
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  @doc """
  What restoring the export entry `entry` (a snapshot's payload) would do to
  games already sent: each sent game the entry does not hold at all, or
  holds with a result other than the one that went out. Empty when the
  restore loses nothing that was sent. Each is
  `%{round:, white:, black:, sent_as:, kind:, restored:}`, with `restored`
  nil for a game the entry does not hold.

  A game is found in the entry as everywhere else: by its identity, then by
  round and players - so a player's FIDE ID or name changed since the
  snapshot does not make a game it holds look taken away (audit F4).

  A game sent as `?` is not changed by any result: its real one is still to
  go out, in the postponed-games file.
  """
  def restore_conflicts(tournament_id, entry) do
    players = Map.new(list(entry, "players"), &{&1["id"], &1})

    key = fn id ->
      case players[id] do
        nil -> nil
        p -> player_key(%{fide_id: p["fide_id"], name: p["name"]})
      end
    end

    games =
      for {r, i} <- Enum.with_index(list(entry, "rounds")),
          {p, j} <- Enum.with_index(r["pairings"] || []) do
        %{
          ref: {i, j},
          round: r["number"],
          game_uid: string_or_nil(p["game_uid"]),
          white_key: key.(p["white_player_id"]),
          black_key: key.(p["black_player_id"]),
          result: p["result"]
        }
      end

    results = Map.new(games, &{&1.ref, &1.result})
    sent = records(tournament_id)
    {matched, _unmatched} = match_records(sent, games)

    restored_by_record =
      for {ref, recs} <- matched, rec <- recs, into: %{}, do: {rec.id, Map.get(results, ref)}

    sent
    |> Enum.sort_by(&{&1.round, &1.id})
    |> Enum.flat_map(fn s ->
      restored = Map.get(restored_by_record, s.id, :missing)

      cond do
        restored == :missing -> [conflict(s, nil)]
        s.sent_as == "?" -> []
        restored != s.sent_as -> [conflict(s, restored)]
        true -> []
      end
    end)
  end

  defp conflict(s, restored) do
    %{
      round: s.round,
      white: key_name(s.white_key),
      black: key_name(s.black_key),
      sent_as: s.sent_as,
      kind: s.kind,
      restored: restored
    }
  end

  defp key_name(nil), do: nil
  defp key_name("fide:" <> id), do: "FIDE " <> id
  defp key_name("name:" <> name), do: name

  defp list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Every postponed game ever recorded in `tournament` - open, played in time
  for its round's report, or played later - as `%{round:, pairing:}`, oldest
  round first. A board counts as postponed once it has carried a
  provisional outcome, which is stamped when it is postponed and kept.
  """
  def all_games(%Tournament{id: id}) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^id and not is_nil(p.provisional_white),
        order_by: [r.number, p.board],
        preload: [:white_player, :black_player],
        select: %{round: r.number, pairing: p}
    )
  end

  @doc """
  The games the postponed-games TRF carries: sent as `?` in a finalised main
  report (`finalised_open`), played since (a real result, not `*`), and not
  yet sent in a postponed-games file.
  """
  def sendable_late_games(%Tournament{id: id}) do
    unplayed = ["", "bye" | Results.postponed_codes()]

    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where:
          r.tournament_id == ^id and p.finalised_open == true and
            p.result not in ^unplayed and is_nil(p.postponed_reported_at) and
            not is_nil(p.white_player_id) and not is_nil(p.black_player_id),
        order_by: [p.played_on, r.number, p.board],
        preload: [:white_player, :black_player],
        select: %{round: r.number, pairing: p}
    )
  end

  @doc """
  Records that `games` (from `sendable_late_games/1`) were sent in a
  postponed-games file, on the boards and in the sent-games record, in one
  write transaction. `:ok`, or - writing nothing -
  `{:error, :already_sent}` when one of them was already sent in one (the
  record's guard, so two requests racing cannot both get through),
  `{:error, :handed_off}`/`{:error, :archived}` on a locked copy, or
  `{:error, :copy_not_confirmed}` on an imported copy nobody has confirmed
  yet (`finalise/3`).
  """
  def mark_late_games_sent(%Tournament{id: tournament_id}, games, opts \\ []) do
    Repo.transaction(
      fn ->
        with :ok <- record_late_send(Repo.get!(Tournament, tournament_id), games),
             {:ok, _receipts, nil} <-
               SentReceipts.record_late(
                 tournament_id,
                 games,
                 late_period_of(games),
                 nil,
                 receipt_opts(opts)
               ) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a postponed-games file: `build` (a function of the fresh tournament
  returning `TrfExport.postponed_export/2`'s `{:ok, text, games}`) builds it
  and its games are marked as sent, in one write transaction - so only the
  request whose record lands gets a file. Its receipt is recorded
  (`PairingsEngine.SentReceipts`); the file goes out as built. Returns
  `{:ok, text, games, %SentReceipt{}}`, or `build`'s error, or
  `mark_late_games_sent/2`'s. `opts` as `send_rounds/4`'s.
  """
  def send_late_games(%Tournament{id: tournament_id}, build, opts \\ []) do
    Repo.transaction(
      fn ->
        fresh = Repo.get!(Tournament, tournament_id)

        with :ok <- late_send_allowed(fresh),
             {:ok, text, games} <- build.(fresh),
             :ok <- record_late_send(fresh, games),
             {:ok, [receipt], text} <-
               SentReceipts.record_late(
                 fresh.id,
                 games,
                 late_period_of(games),
                 text,
                 receipt_opts(opts)
               ) do
          {text, games, receipt}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, {text, games, receipt}} -> {:ok, text, games, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp late_period_of([game | _]), do: late_period(game)
  defp late_period_of([]), do: nil

  defp late_send_allowed(%Tournament{} = tournament) do
    with :ok <- PairingsEngine.Tournaments.ensure_writable(tournament) do
      if is_nil(tournament.send_confirmation_needed),
        do: :ok,
        else: {:error, :copy_not_confirmed}
    end
  end

  defp record_late_send(%Tournament{} = tournament, games) do
    ids = Enum.map(games, & &1.pairing.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    fresh =
      Repo.all(
        from p in Pairing,
          where: p.id in ^ids,
          preload: [:white_player, :black_player]
      )
      |> Map.new(&{&1.id, &1})

    with :ok <- late_send_allowed(tournament),
         :ok <-
           if(Enum.any?(fresh, fn {_id, p} -> not is_nil(p.postponed_reported_at) end),
             do: {:error, :already_sent},
             else: :ok
           ),
         # The result each game carried in the file, on the board as it is
         # stored (its identity, its players), recorded through the guard.
         :ok <-
           record_sent(
             tournament.id,
             for(
               %{round: round, pairing: p} <- games,
               do: {round, Map.get(fresh, p.id, p), p.result}
             ),
             "postponed",
             now
           ) do
      mark(ids, postponed_reported_at: now)
    end
  end

  # Past this many placements the exact search gives up and first-fit
  # stands. A club's postponed games number in the tens, where the search
  # finishes instantly; the cap only keeps a pathological input from
  # hanging a download.
  @pack_budget 200_000

  @doc """
  Packs `games` (anything with `white_player_id` and `black_player_id`, in
  the order they should come - by date played) into as few rounds as
  possible with nobody playing twice in one round. Returns a list of rounds,
  each a list of games in input order.

  The fewest rounds possible is at least the most games any one player has.
  That many is tried first, then one more at a time, by exhaustive search
  within a budget; if the budget runs out, first-fit in date order is used,
  which is never wrong - only possibly one round longer than it had to be.
  """
  def pack([]), do: []

  def pack(games) do
    lower =
      games
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.frequencies()
      |> Map.values()
      |> Enum.max()

    Enum.find_value(lower..length(games), fn k -> exact_pack(games, k) end) ||
      first_fit(games)
  end

  defp exact_pack(games, k) do
    Process.put(:pack_budget, @pack_budget)
    slots = List.duplicate(MapSet.new(), k)

    case place(games, slots, []) do
      {:ok, assignment} -> to_rounds(games, Enum.reverse(assignment), k)
      :none -> nil
    end
  end

  defp place([], _slots, acc), do: {:ok, acc}

  defp place([game | rest], slots, acc) do
    budget = Process.get(:pack_budget) - 1
    Process.put(:pack_budget, budget)

    if budget < 0 do
      :none
    else
      slots
      |> Enum.with_index()
      |> Enum.find_value(:none, fn {used, i} ->
        if MapSet.member?(used, game.white_player_id) or
             MapSet.member?(used, game.black_player_id) do
          nil
        else
          used = used |> MapSet.put(game.white_player_id) |> MapSet.put(game.black_player_id)

          case place(rest, List.replace_at(slots, i, used), [i | acc]) do
            {:ok, _} = ok -> ok
            :none -> nil
          end
        end
      end)
    end
  end

  defp first_fit(games) do
    {rounds, _used} =
      Enum.reduce(games, {[], []}, fn game, {rounds, used} ->
        free =
          Enum.find_index(used, fn set ->
            not MapSet.member?(set, game.white_player_id) and
              not MapSet.member?(set, game.black_player_id)
          end)

        pair = MapSet.new([game.white_player_id, game.black_player_id])

        case free do
          nil ->
            {rounds ++ [[game]], used ++ [pair]}

          i ->
            {List.update_at(rounds, i, &(&1 ++ [game])),
             List.update_at(used, i, &MapSet.union(&1, pair))}
        end
      end)

    rounds
  end

  defp to_rounds(games, assignment, k) do
    by_round = games |> Enum.zip(assignment) |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    for i <- 0..(k - 1), games = Map.get(by_round, i, []), games != [], do: games
  end
end
