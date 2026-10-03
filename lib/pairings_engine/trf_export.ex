defmodule PairingsEngine.TrfExport do
  @moduledoc """
  User-facing FIDE TRF16 export of a tournament's full roster, as opposed to
  `PairingsEngine.Pairing.javafo_input/2` (a JaVaFo-only input file, built
  from active players and fed straight into the pairing engine - never
  downloaded by a user).

  The distinguishing feature here is **round selection**: `export/2` can
  produce a TRF containing only a chosen subset of rounds - the header's
  round-dates line and every player's per-round result columns are trimmed
  to match, and points are recomputed from the filtered games only. See
  `parse_rounds/2` for the accepted `rounds` query-param syntax and
  `docs/import-export.md` for the user-facing reference.

  Only players who have actually been included in a paired round (i.e. have
  a `pairing_number`) are exported - see
  `PairingsEngine.Pairing.trf_player_rows/2`.
  """

  import Ecto.Query, only: [from: 2]

  alias PairingsEngine.{Federation, Pairing, Standings, TeamStandings, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # The app's one TRF16 implementation, and the one TRF error type that goes
  # with it. There used to be a local `PairingsEngine.Trf` as well - a
  # photocopy Ainalrami's was taken from, which then kept growing while the
  # copy stood still. What is left in this app is the adapter above: turning
  # Ecto structs into the plain maps the writer takes.
  alias Ainalrami.Trf
  alias Ainalrami.Trf.ValidationError

  @doc """
  Builds the TRF26 text for `tournament`, limited to `rounds_spec` (either a
  raw query-param string per `parse_rounds/2`, or an already-parsed list of
  round numbers). Defaults to every paired round when `rounds_spec` is
  `nil`/blank. `dialect: :engine` asks for the older `XX*`/`BB*` spelling the
  pairing programs read; the default is FIDE's TRF26 (see `Ainalrami.Trf`,
  "Two dialects").

  Returns `{:ok, text}`, or `{:error, %Ainalrami.Trf.ValidationError{}}`
  if the filtered result set fails `Trf`'s own legality validation (an
  unrecognized or mutually-inconsistent result code) - never raises.
  """
  def export(tournament, rounds_spec \\ nil, opts \\ []) do
    with :ok <- ensure_round_dates(tournament, rounds_spec) do
      text =
        tournament
        |> build(rounds_spec, opts)
        |> mark_copy(
          copy_comments(tournament, rounds_spec, opts) ++ fide_mode_comments(tournament, opts)
        )

      {:ok, text}
    end
  rescue
    e in ValidationError -> {:error, e}
  end

  ## ---------- a copy is marked as one ----------
  #
  # A file downloaded as a copy, and any file carrying a round already sent
  # for rating, says so in its own text (audit 2026-10-01, F7): before this
  # the "Download a copy" and "All rounds" files were byte for byte the file
  # that went to the rating officer, and nothing in one told anybody not to
  # send it again.
  #
  # The mark is TRF's comment line, `###` - the form FIDE's VCL4THP asks a
  # pairing program to write its own notes in (`docs/design-fide-mode.md`,
  # section 4), which `Ainalrami.Trf.parse/1` skips, so the file stays a
  # valid TRF that reads exactly as before. No record of the format is
  # invented or changed: the tournament's name, dates and results are left
  # alone. English and ASCII only, like every other line in a file that
  # leaves the building. Only in the TRF26 dialect: the older spelling is
  # read by pairing programs, and its filename already says COPY.
  #
  # `copy: true` (the download routes that are not "Send") marks it always;
  # without it, it is marked when a round in it was already sent - never the
  # case for the file "Send" hands out, which is built before its rounds are
  # marked (`PostponedGames.send_rounds/4`).
  defp copy_comments(tournament, rounds_spec, opts) do
    if Keyword.get(opts, :dialect, :trf26) == :trf26 do
      paired = Pairing.paired_rounds_count(tournament.id)
      rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)
      sent = Enum.filter(PairingsEngine.PostponedGames.sent_rounds(tournament), &(&1 in rounds))

      # Each round's receipt follows the mark: whose copy this is
      # ("copy of R5-7F2A"), or that the round was never sent
      # (`PairingsEngine.SentReceipts.copy_lines/2`).
      cond do
        sent != [] ->
          [
            "COPY - NOT FOR RATING. " <>
              String.capitalize(describe_rounds(sent)) <>
              " of this file already went to the rating officer: sending this file " <>
              "again would rate those games twice."
            | PairingsEngine.SentReceipts.copy_lines(tournament.id, rounds)
          ]

        Keyword.get(opts, :copy, false) ->
          [
            "COPY - NOT FOR RATING. Downloaded as a copy: results are sent with " <>
              "OpenPairings' Send, which records what went out."
            | PairingsEngine.SentReceipts.copy_lines(tournament.id, rounds)
          ]

        true ->
          []
      end
    else
      []
    end
  end

  ## ---------- leaving FIDE mode is in the file ----------
  #
  # VCL4THP Q44: once a tournament has left FIDE mode, its report says so,
  # and from which round, so whoever checks it knows where the pairings stop
  # being the pairing system's own. `fide_compliance_lost_round` is that
  # round - the number of rounds that existed when it happened, 0 for before
  # the first was paired - and nothing ever clears it, so neither does this.
  # Written in the style of the TEC manual draft's PIBE lines
  # (`### <Type> @ Round N`); the draft fixes no wording for this one.
  # TRF26 only, like the copy mark: the engines read the other spelling.
  defp fide_mode_comments(%Tournament{} = tournament, opts) do
    case {Keyword.get(opts, :dialect, :trf26), tournament.fide_compliance_lost_round} do
      {:trf26, 0} -> ["FIDE mode exited before Round 1 was paired"]
      {:trf26, round} when is_integer(round) -> ["FIDE mode exited @ Round #{round}"]
      _ -> []
    end
  end

  @doc """
  Puts `comments` into the TRF `text` as `###` comment lines, after the
  header records and before the players - where a reader opening the file
  sees them first.
  """
  def mark_copy(text, []), do: text

  def mark_copy(text, comments) do
    {head, rest} =
      text
      |> String.split("\r\n")
      |> Enum.split_while(&(&1 != "" and not String.starts_with?(&1, "001")))

    Enum.join(head ++ Enum.map(comments, &("### " <> &1)) ++ rest, "\r\n")
  end

  # SWAR parity #23 (manual standings override) is deliberately NOT
  # surfaced in this file - see docs/manual-standings.md for the full
  # reasoning. In short: the FIDE "086-089 Rank" column and the "005-008
  # Starting rank" column both carry `pairing_number` in this codebase (see
  # `Pairing.trf_player_rows/2`), and every game's opponent cross-reference
  # is baked against that same value - rewriting it per player to the
  # standings rank would desync those references and fail
  # `Trf.serialize/1`'s own cross-check, so this doesn't touch it. There is
  # therefore no hidden override to disclose in this file at all: the TRF's
  # rank column was never affected by manual ranking in the first place.
  # The UI (the page offering this download) carries the caveat instead -
  # see `PairingsEngineWeb.PairingsLive`.

  @doc """
  Parses a `rounds` query-param string into a sorted, deduped list of round
  numbers clamped to `1..max_round`.

  Accepts a comma-separated mix of single round numbers and dash ranges,
  e.g. `"1-5"`, `"1,2,4"`, or `"1-3,6,8-9"`. Out-of-range or unparsable
  tokens are silently dropped rather than raising. `nil`, `""`, or a spec
  that yields no valid rounds at all defaults to every round in
  `1..max_round`.
  """
  def parse_rounds(spec, max_round)

  def parse_rounds(nil, max_round), do: all_rounds(max_round)
  def parse_rounds("", max_round), do: all_rounds(max_round)

  def parse_rounds(spec, max_round) when is_binary(spec) do
    rounds =
      spec
      |> String.split(",", trim: true)
      |> Enum.flat_map(&parse_token(&1, max_round))
      |> Enum.uniq()
      |> Enum.sort()

    if rounds == [], do: all_rounds(max_round), else: rounds
  end

  defp all_rounds(max_round) when is_integer(max_round) and max_round > 0,
    do: Enum.to_list(1..max_round)

  defp all_rounds(_), do: []

  defp parse_token(token, max_round) do
    case token |> String.trim() |> String.split("-", trim: true) do
      [a, b] ->
        with {lo, ""} <- Integer.parse(String.trim(a)),
             {hi, ""} <- Integer.parse(String.trim(b)),
             true <- lo <= hi do
          Enum.to_list(max(lo, 1)..min(hi, max_round)//1)
        else
          _ -> []
        end

      [a] ->
        case Integer.parse(a) do
          {n, ""} when n >= 1 and n <= max_round -> [n]
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  Resolves the export metadata needed to build the download filename (see
  `PairingsEngineWeb.ExportController`): the concrete list of rounds that
  `export/2` will produce for the same `rounds_spec` (after clamping/
  defaulting per `parse_rounds/2`), and the FIDE tournament ID that applies
  to that round range per `applicable_fide_id/2`. Kept separate from
  `export/2` itself so the controller can compute the filename without
  parsing the TRF text back out just to find out which rounds/ID it used.
  """
  def export_meta(tournament, rounds_spec \\ nil) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)

    %{rounds: rounds, fide_id: applicable_fide_id(tournament, rounds)}
  end

  @doc """
  The FIDE tournament ID that applies to `rounds` (a list of round numbers,
  e.g. from `parse_rounds/2`) - SWAR's "this FIDE ID applies to rounds X-Y"
  model (`tournament.fide_id_ranges`, see
  `PairingsEngine.Tournaments.Tournament`'s schema doc).

  Resolution:

    * If exactly one configured range fully covers `rounds` (its
      `from_round..to_round` spans at least `min(rounds)..max(rounds)`),
      that range's ID is used - this is the common case (a report cleanly
      split by round).
    * Otherwise - no ranges configured, the round span crosses more than
      one range's boundary, only partially overlaps one, or matches none -
      falls back to the tournament-wide `tournament.fide_tournament_id`.
      This never raises: an unresolvable/blank case simply yields `nil`,
      which the filename builder renders as an omitted segment (e.g. a
      tournament that isn't FIDE-homologated at all).

  Returns `nil` rather than `""` for "no ID applies", regardless of which
  field it came from.
  """
  def applicable_fide_id(tournament, rounds) do
    with [_ | _] <- rounds,
         min_r = Enum.min(rounds),
         max_r = Enum.max(rounds),
         [range] <-
           Enum.filter(tournament.fide_id_ranges || [], fn r ->
             r["from_round"] <= min_r and r["to_round"] >= max_r
           end) do
      blank_to_nil(range["fide_tournament_id"])
    else
      _ -> blank_to_nil(tournament.fide_tournament_id)
    end
  end

  defp build(tournament, rounds_spec, opts) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)
    dialect = Keyword.get(opts, :dialect, :trf26)

    players = Tournaments.list_players(tournament.id)

    trf_players =
      tournament
      |> Pairing.trf_player_rows(players)
      |> Enum.map(&report_unknown(&1, dialect))
      |> Enum.map(&filter_player_games(&1, rounds, tournament))
      # Baku virtual points for the rounds in the file. The report had
      # left them out altogether; TRF26 wants them (`250`) for pairing.
      |> then(&Pairing.accelerated_rows(tournament, &1, players, length(rounds)))
      |> append_future_byes(tournament, rounds, paired)
      |> with_final_ranks(tournament, rounds, dialect)

    last_round = Enum.reduce(trf_players, length(rounds), &max(length(&1.games), &2))

    # Postponed games, as `{starting rank, column}` - see `mark_unknown/2`.
    unknown = if dialect == :trf26, do: postponed_columns(trf_players), else: []
    point_system = unknown_point_value(Tournament.engine_point_system(tournament), unknown)

    tournament
    |> serialize(trf_players, players, rounds, last_round, point_system, dialect)
    |> mark_unknown(unknown)
  end

  # The rank column of the 001 record (86-89) is the player's place in the
  # standings after the file's last round - not the starting rank in 5-8,
  # which is what the opponent columns refer to and which stays the TPN. The
  # two had been written alike, so a pairing checker reading the file
  # (`ainalrami -c`, what FIDE's testers run - VCL4THP Q21, Q217) reported
  # nearly every place as one the tie-breaks do not give. The place is
  # `Standings`' C.07 order over the rounds in the file; a hand-set order
  # (docs/manual-standings.md) stays out of the report, as before.
  #
  # TRF26 only: the engine dialect is what a pairing program reads, byte for
  # byte the input both engines get. Not for a team event, whose places are
  # the teams' (`team_records/2`), nor for Keizer, which has its own ladder
  # and no FIDE tie-breaks. Nor for a file of chosen rounds that does not
  # start at round 1: its places would be computed from games it leaves out.
  defp with_final_ranks(rows, tournament, rounds, :trf26) do
    if Tournament.team?(tournament) or tournament.pairing_system == "keizer" or
         rounds == [] or rounds != Enum.to_list(1..Enum.max(rounds)) do
      rows
    else
      place =
        tournament
        |> PairingsEngine.Standings.standings(through_round: Enum.max(rounds))
        |> Map.new(&{&1.player.id, &1.rank})

      Enum.map(rows, fn row ->
        case Map.fetch(place, row.id) do
          {:ok, rank} -> Map.put(row, :final_rank, rank)
          :error -> row
        end
      end)
    end
  end

  defp with_final_ranks(rows, _tournament, _rounds, _dialect), do: rows

  defp serialize(tournament, trf_players, players, rounds, last_round, point_system, dialect) do
    Trf.serialize(
      %{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          # Defensive normalization: the SWAR importer already normalizes a
          # Belgian regional marker (VSF/FEFB/FRBE/"FIDE"/...) to "BEL" on
          # import, but a tournament imported before that normalization
          # existed may still carry the raw marker in the database - reusing
          # the same helper here means it exports "032 BEL" either way, with
          # no re-import required. A no-op for every other federation value
          # (see `PairingsEngine.Federation.normalize/1`).
          federation: Federation.normalize(tournament.federation),
          start_date: tournament.start_date,
          end_date: tournament.end_date,
          number_of_rated_players: Enum.count(trf_players, &((&1.fide_rating || 0) > 0)),
          type: tournament.type,
          chief_arbiter: chief_arbiter_line(tournament),
          deputy_arbiters: deputy_arbiter_lines(tournament),
          time_control: blank_to_nil(tournament.rate_of_play),
          # The tournament's LENGTH, not how much of it this file carries.
          #
          # It used to be the latter, on the reasoning that a `?rounds=1-3`
          # export of a 5-round event should describe itself honestly as 3
          # rounds. That conflated two questions: how many rounds are in
          # this file (which the columns already answer) and how many
          # rounds the event has, which is what TRF26 defines `142` as and
          # what every reader does with it. A pairing engine handed the
          # file applies the final-round colour exception by this number,
          # so understating it makes the engine treat an ordinary round as
          # the last one. `round_dates` below stays filtered to `rounds` -
          # a date the file does not cover is a date it should not claim.
          number_of_rounds: max(tournament.rounds_count || 0, last_round),
          round_dates: filter_round_dates(tournament.round_dates, rounds),
          generator: "OpenPairings v#{app_version()}",
          # TRF26's headers and records - what FIDE reads, in FIDE's
          # spelling. `192` names the system that paired the boards, `202`
          # the tie-breaks as configured (already FIDE's own codes), `222`
          # the rate of play where its wording encodes (`RateOfPlay`),
          # `162` a point system other than 1/half/0, `260` the prohibited
          # pairings - explicit ones and those by club or federation.
          type_code: tournament_type_code(tournament),
          # C.04.3 Art. 5.1 / C.04.6 Art. 4.1: the initial colour drawn by
          # lot (or set by the arbiter), when one is on record - `152` in a
          # TRF26 report, `XXC white1`/`black1` in the engine dialect, the
          # spelling JaVaFo reads. Nothing when there is none (a round robin,
          # or an event paired before the draw was stored), as before.
          initial_colour: initial_colour_code(tournament),
          tie_breaks: tie_break_codes(tournament),
          time_control_code: PairingsEngine.RateOfPlay.trf26_code(tournament.rate_of_play),
          point_system: point_system,
          free_points: free_point_records(players, tournament),
          forbidden_pairs:
            Pairing.forbidden_pairs(tournament.id, players) ++
              Pairing.exclusion_pairs(tournament, players),
          team_point_system: team_point_system(tournament, dialect),
          team_pab: team_pab(tournament, rounds, dialect),
          forfeited_matches: team_double_forfeits(tournament, rounds, dialect)
        },
        players: trf_players,
        teams: team_records(tournament, players, trf_players, dialect, rounds)
      },
      # `:trf26` for the file an arbiter uploads; `:engine` on request, for
      # a pairing program that reads the older `XX*`/`BB*` spelling.
      dialect: dialect,
      xxc: dialect == :engine,
      column_legend: true,
      # This file leaves the building - it is what an arbiter submits to
      # FIDE - so it must survive a byte-oriented reader. See
      # `Trf.serialize/2`'s `:ascii` option.
      ascii: true
    )
  end

  ## ---------- postponed games: TRF26's `?` ----------
  #
  # A postponed game (`"*"`, VCL4THP Q164-165) is written as TRF26's unknown
  # result, `?`, on both players' `001` lines, and the `162` record declares
  # what an unknown result is worth with `X` - a draw, because that is what
  # the game counts as until it is played, so a reader adding up the columns
  # gets the same points column this file states. A file carrying `?` is by
  # construction not a final report: no reader can take an unknown result
  # for a known one.
  #
  # `Ainalrami.Trf.serialize/2` refuses `?` in both dialects (its moduledoc,
  # "The `?` unknown result"). So the game goes to the writer as the draw
  # `Pairing.trf_player_rows/3` already hands the engine, and the character
  # is swapped afterwards at the one column the round block defines for it.
  # The swap checks the character it replaces, so a column that is not the
  # draw it expects raises rather than being written over. The engine
  # dialect keeps the draw: that spelling exists to be read by a pairing
  # program, which pairs a postponed game as a draw and cannot read `?`.
  #
  # When Ainalrami's writer accepts `?` (an `allow_unknown_result` switch on
  # `serialize/2`, which today only `parse/1` passes), this becomes a
  # `result: "?"` on the game and `mark_unknown/2` goes away.
  # In a TRF26 report every game that is `?` - an open postponed game, and
  # one that was sent as `?` in a report marked as sent (`finalised_open`),
  # whose real result goes in the postponed-games file and never here - is
  # written as the draw `mark_unknown/2` turns into `?`, and scores what the
  # file's own `X` says: a draw. So the points column adds up from the file
  # itself, whatever the club counts a postponed game as in its standings.
  # A file for sending that disagreed with itself would be wrong data.
  defp report_unknown(row, :trf26) do
    games =
      Enum.map(row.games, fn game ->
        if Map.get(game, :postponed) == true or Map.get(game, :finalised_open) == true do
          %{game | result: "="} |> Map.put(:postponed, true) |> Map.put(:provisional_points, nil)
        else
          game
        end
      end)

    %{row | games: games}
  end

  # The older spelling has no `?`: a postponed game stays the `=` a pairing
  # program reads. It is scored as that draw too, not at what the tournament
  # counts it as, so this file adds up from itself as well - a downloaded
  # file is checked against its own games. Only the file the app hands its
  # own engine (`Pairing.trf_game/4`) carries the provisional points, since
  # that one pairs with them and is never sent anywhere.
  defp report_unknown(row, _dialect) do
    games =
      Enum.map(row.games, fn game ->
        if Map.get(game, :postponed) == true,
          do: Map.put(game, :provisional_points, nil),
          else: game
      end)

    %{row | games: games}
  end

  ## ---------- the postponed-games file ----------

  @doc """
  The TRF26 file for postponed games that were sent as `?` in a report
  marked as sent and have been played since (`PostponedGames.sendable_late_games/1`),
  packed into as few extra rounds as possible with nobody twice in a round
  (`PostponedGames.pack/1`). Each round is dated by the latest date one of
  its games was played on. Only the players in those games are in the file,
  under their own starting ranks, so every opponent reference is the same
  number it is in the main report.

  ## A tournament of its own

  The file is reported to FIDE as a separate tournament - the way late
  games are reported in practice ("Clubkampioenschap 25-26 uitgestelde
  partijen"): its `012` name is `PostponedGames.report_name/1` (the
  arbiter's, or the event's name + "postponed games"), its `042`/`052`
  start and end dates are the first and last day its games were played,
  and its FIDE tournament ID is its own (`postponed_fide_tournament_id`,
  in the filename like the main report's). It carries only its games, and
  the games of one FIDE rating period only (`PostponedGames.rating_period/1`,
  a calendar month): one file per period, never two periods in one.

  Returns `{:ok, text, games}` - the games it carries, for the caller to
  mark as sent - or `{:error, :nothing_to_send}`,
  `{:error, {:mixed_periods, [period]}}` (the chosen games were played in
  more than one rating period: choose one with `period:`),
  `{:error, :played_on_missing}` (a chosen game has no date played, so its
  rating period is unknown) or `{:error, %ValidationError{}}`. Before it
  returns a file it reads it back and checks it says exactly what was
  meant: every game once, nobody twice in a round, the result each board
  holds. A file that fails that is not returned at all.

  Options, from the Export page's postponed-games part:

    * `period:` - the first day of the rating period (month) to send;
      only that period's games are considered. nil (the default) takes
      every chosen game, which must then share one period.
    * `games:` - the pairing ids to send now; the others wait for a later
      file. nil (the default) sends every sendable game. Ids that are not
      sendable are ignored.
    * `dates:` - a date per extra round, in order, to report instead of the
      latest date its games were played on; a nil entry, or a list shorter
      than the rounds, keeps that default.
  """
  def postponed_export(tournament, opts \\ []) do
    chosen = Keyword.get(opts, :games)
    period = Keyword.get(opts, :period)

    games =
      tournament
      |> PairingsEngine.PostponedGames.sendable_late_games()
      |> Enum.filter(&(is_nil(chosen) or &1.pairing.id in chosen))
      |> Enum.filter(&(is_nil(period) or PairingsEngine.PostponedGames.late_period(&1) == period))

    periods = games |> Enum.map(&PairingsEngine.PostponedGames.late_period/1) |> Enum.uniq()

    cond do
      games == [] ->
        {:error, :nothing_to_send}

      nil in periods ->
        {:error, :played_on_missing}

      length(periods) > 1 ->
        {:error, {:mixed_periods, Enum.sort(periods, Date)}}

      true ->
        rounds = games |> Enum.map(& &1.pairing) |> PairingsEngine.PostponedGames.pack()
        text = build_postponed(tournament, rounds, Keyword.get(opts, :dates, []))
        :ok = verify_postponed!(text, rounds)
        {:ok, mark_copy(text, postponed_copy_comments(opts)), games}
    end
  rescue
    e in ValidationError -> {:error, e}
  end

  defp postponed_copy_comments(opts) do
    if Keyword.get(opts, :copy, false),
      do: [
        "COPY - NOT FOR RATING. Downloaded as a copy: the postponed-games file is sent " <>
          "with OpenPairings' Send, which records what went out.",
        # Only games not sent in a postponed-games file yet are offered.
        "Postponed games in this file: never sent."
      ],
      else: []
  end

  @doc """
  The date an extra round of the postponed-games file reports when nobody
  sets one: the latest date one of its games was played on, or nil.
  """
  def postponed_round_date(games) do
    games
    |> Enum.map(& &1.played_on)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(Date, fn -> nil end)
  end

  defp build_postponed(tournament, rounds, set_dates) do
    roster = Pairing.full_roster_players(tournament.id) |> Map.new(&{&1.id, &1})

    ids =
      rounds
      |> List.flatten()
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.uniq()

    blank = %{opponent_rank: nil, colour: nil, result: nil}

    rows =
      ids
      |> Enum.map(&Map.fetch!(roster, &1))
      |> Enum.sort_by(& &1.pairing_number)
      |> Enum.map(fn p ->
        games =
          Enum.map(rounds, fn games ->
            case Enum.find(games, &(p.id in [&1.white_player_id, &1.black_player_id])) do
              nil -> blank
              pairing -> Pairing.trf_game(pairing, p.id, roster, tournament)
            end
          end)

        %{
          rank: p.pairing_number,
          sex: p.sex,
          title: p.title,
          name: p.name,
          fide_rating: p.fide_rating,
          federation: p.federation,
          fide_number: p.fide_id,
          points: Pairing.player_points(games, tournament),
          games: games
        }
      end)

    dates =
      rounds
      |> Enum.with_index()
      |> Enum.map(fn {games, i} -> Enum.at(set_dates, i) || postponed_round_date(games) end)

    # Its own tournament: dated by the games it carries (see `postponed_export/2`).
    played = rounds |> List.flatten() |> Enum.map(& &1.played_on) |> Enum.reject(&is_nil/1)

    Trf.serialize(
      %{
        tournament: %{
          name: PairingsEngine.PostponedGames.report_name(tournament),
          city: tournament.city,
          federation: Federation.normalize(tournament.federation),
          start_date: iso(Enum.min(played, Date, fn -> nil end)),
          end_date: iso(Enum.max(played, Date, fn -> nil end)),
          number_of_rated_players: Enum.count(rows, &((&1.fide_rating || 0) > 0)),
          type: tournament.type,
          chief_arbiter: chief_arbiter_line(tournament),
          deputy_arbiters: deputy_arbiter_lines(tournament),
          time_control: blank_to_nil(tournament.rate_of_play),
          number_of_rounds: length(rounds),
          round_dates: Enum.map(dates, &(&1 && Date.to_iso8601(&1))),
          generator: "OpenPairings v#{app_version()}",
          type_code: tournament_type_code(tournament),
          time_control_code: PairingsEngine.RateOfPlay.trf26_code(tournament.rate_of_play),
          point_system: Tournament.engine_point_system(tournament)
        },
        players: rows
      },
      dialect: :trf26,
      column_legend: true,
      ascii: true
    )
  end

  # Reads the file back and checks it against what was meant to be in it.
  # Nothing here trusts the builder above: a file for sending is checked the
  # way the federation will read it.
  defp verify_postponed!(text, rounds) do
    parsed = Trf.parse(text)
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    rounds
    |> Enum.with_index()
    |> Enum.each(fn {games, index} ->
      in_round =
        parsed.players
        |> Enum.filter(&(Enum.at(&1.games, index, %{})[:opponent_rank] != nil))
        |> length()

      if in_round != 2 * length(games) do
        raise ValidationError,
          message:
            "postponed-games file, round #{index + 1}: #{in_round} players with a game, " <>
              "#{2 * length(games)} expected"
      end

      # Each game where it was meant to be: White against Black, in this
      # round, with the colours the board had.
      for pairing <- games do
        white = pairing.white_player.pairing_number
        black = pairing.black_player.pairing_number
        w = by_rank |> Map.fetch!(white) |> Map.fetch!(:games) |> Enum.at(index)
        b = by_rank |> Map.fetch!(black) |> Map.fetch!(:games) |> Enum.at(index)

        unless w[:opponent_rank] == black and b[:opponent_rank] == white and
                 w[:colour] == "w" and b[:colour] == "b" do
          raise ValidationError,
            message:
              "postponed-games file, round #{index + 1}: the game #{white}-#{black} " <>
                "is not written as it was played"
        end
      end
    end)

    total =
      parsed.players |> Enum.flat_map(& &1.games) |> Enum.count(&(&1[:opponent_rank] != nil))

    if total != 2 * length(List.flatten(rounds)) or map_size(by_rank) != length(parsed.players) do
      raise ValidationError, message: "postponed-games file does not carry each game exactly once"
    end

    :ok
  end

  defp postponed_columns(trf_players) do
    for player <- trf_players,
        {game, column} <- Enum.with_index(player.games, 1),
        Map.get(game, :postponed) == true,
        do: {player.rank, column}
  end

  defp unknown_point_value(system, []), do: system
  defp unknown_point_value(system, _unknown), do: Map.put(system, :unknown, system.draw)

  defp mark_unknown(text, []), do: text

  defp mark_unknown(text, unknown) do
    by_rank = Enum.group_by(unknown, &elem(&1, 0), &elem(&1, 1))

    text
    |> String.split("\r\n")
    |> Enum.map(&mark_line(&1, by_rank))
    |> Enum.join("\r\n")
  end

  defp mark_line("001" <> _ = line, by_rank) do
    rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()

    Enum.reduce(Map.get(by_rank, rank, []), line, fn column, acc ->
      # Round blocks start at column 92, ten columns each, the result in the
      # eighth: column 99 for round 1. Zero-based here, one-based in TRF.
      at = 98 + (column - 1) * 10

      case binary_part(acc, at, 1) do
        "=" ->
          binary_part(acc, 0, at) <> "?" <> binary_part(acc, at + 1, byte_size(acc) - at - 1)

        other ->
          raise ValidationError,
            message:
              "postponed game of starting rank #{rank}, round #{column}: expected the draw " <>
                "it is written as, found #{inspect(other)}"
      end
    end)
  end

  defp mark_line(line, _by_rank), do: line

  # The team section: TRF26's `310` once every team has a `pairing_number`
  # (round 1 paired - `PairingsEngine.Tournaments.Team`) AND the file is the
  # `:trf26` dialect, the older `013` otherwise, each with its name and the
  # starting ranks of its players in board order - which, in this app, are
  # their pairing numbers, the same values every game's opponent column
  # carries. Only players the file actually contains are listed, so a record
  # never names a rank with no `001` line behind it.
  #
  # A `310` record also carries the team's own number, match points, game
  # points and final rank - `PairingsEngine.TeamStandings.standings/1`, the
  # same numbers the Team standings page shows - so a file this app writes
  # round-trips through `ainalrami -c`'s team-rank check (`docs/team-tournaments.md`).
  # The `:engine` dialect stays plain `013`: a pairing program reading this
  # file to pair the next round wants rosters, not standings, and every
  # other TRF26-only record (`162`/`260`'s `BB*`/`XX*` alternates) is kept
  # out of it the same way.
  #
  # Empty for an individual tournament, so its file is byte-for-byte what it
  # was: the `082` header was already written as 0, and no team record
  # appears. The individual games stay on the `001` lines exactly as before;
  # the team section only says who played for whom.
  #
  # A player moved to another team mid-event (allowed outside FIDE mode,
  # `Tournaments.set_player_team/3`) is listed under the team they PLAYED
  # for in the exported rounds (`Player.team_history`), not the team they
  # are on now: the record says who played for whom. A `310` lists a player
  # once, so one who played for two teams goes under the one they played
  # the most rounds for (the later on a tie); such a player is appended
  # after the team's own roster. Every other player is listed exactly as
  # before.
  defp team_records(tournament, players, trf_players, dialect, rounds) do
    if Tournament.team?(tournament) do
      exported = MapSet.new(trf_players, & &1.rank)
      teams = Tournaments.list_teams(tournament.id)
      numbered? = dialect == :trf26 and teams != [] and Enum.all?(teams, & &1.pairing_number)

      # The match points, game points and rank after the file's LAST round,
      # and only for a file that starts at round 1 - the standings of a file
      # of chosen rounds would count games it leaves out, the same rule as
      # the `001` rank (`with_final_ranks/4`). Such a file keeps its team
      # numbers and rosters.
      from_one? = rounds != [] and rounds == Enum.to_list(1..Enum.max(rounds))

      standings_by_id =
        if numbered? and from_one?,
          do:
            tournament
            |> TeamStandings.standings(through_round: Enum.max(rounds))
            |> Map.new(&{&1.team.id, &1}),
          else: %{}

      played_for = played_for(tournament, rounds)
      team_of = fn p -> Map.get(played_for, p.id, p.team_id) end

      Enum.map(teams, fn team ->
        {own, former} =
          players
          |> Enum.filter(&(team_of.(&1) == team.id))
          |> Enum.split_with(&(&1.team_id == team.id))

        ranks =
          (Tournaments.sort_roster(own) ++ Enum.sort_by(former, & &1.pairing_number))
          |> Enum.map(& &1.pairing_number)
          |> Enum.filter(&MapSet.member?(exported, &1))

        base = %{name: team.name, player_ranks: ranks}

        base = if numbered?, do: Map.put(base, :number, team.pairing_number), else: base

        case Map.get(standings_by_id, team.id) do
          nil ->
            base

          entry ->
            Map.merge(base, %{
              match_points: entry.mp,
              game_points: entry.gp,
              final_rank: entry.rank
            })
        end
      end)
    else
      []
    end
  end

  # `%{player_id => team_id}` for the players who played for a team other
  # than the one they are on now in `rounds`: a player moved between teams
  # after playing (`Player.team_history`, outside FIDE mode only), under the
  # team they were on in the most of the exported rounds they sat at a board
  # in, the later on a tie. Empty when nobody moved.
  defp played_for(tournament, rounds) do
    moved =
      tournament.id
      |> Tournaments.list_players()
      |> Enum.filter(&((&1.team_history || []) != []))

    if moved == [] do
      %{}
    else
      wanted = MapSet.new(rounds)
      seated = seated_rounds(tournament.id, wanted)

      for player <- moved,
          played = Map.get(seated, player.id, []),
          played != [],
          {team, _} =
            played
            |> Enum.group_by(&Tournaments.team_in_round(player, &1))
            |> Enum.max_by(fn {_team, rs} -> {length(rs), Enum.max(rs)} end),
          team != player.team_id,
          into: %{},
          do: {player.id, team}
    end
  end

  # `%{player_id => [round]}`: the rounds in `wanted` each player sat at a board.
  defp seated_rounds(tournament_id, wanted) do
    PairingsEngine.Repo.all(
      from p in PairingsEngine.Tournaments.Pairing,
        join: r in assoc(p, :round),
        where: r.tournament_id == ^tournament_id,
        select: {r.number, p.white_player_id, p.black_player_id}
    )
    |> Enum.filter(fn {n, _, _} -> MapSet.member?(wanted, n) end)
    |> Enum.flat_map(fn {n, w, b} -> [{w, n}, {b, n}] end)
    |> Enum.reject(fn {id, _} -> is_nil(id) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # TRF26's `330` for each match this app recorded as a DOUBLE forfeit
  # (`PairingsEngine.TeamMatches.double_forfeit/2`): type `--`, both teams
  # lost by forfeit, the team with White on board 1 named first. Its boards
  # are on the `001` lines too (`-` against each other); the record says
  # what the boards alone cannot - that the match itself was a double
  # forfeit, lost by both, rather than a drawn 0-0. Round position is the
  # file's own column, as for `320`.
  defp team_double_forfeits(tournament, rounds, dialect) do
    if dialect == :trf26 and Tournament.paired_as_teams?(tournament) do
      numbers = tournament.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1.pairing_number})
      position = rounds |> Enum.with_index(1) |> Map.new()

      for m <- TeamStandings.matches(tournament),
          m.double_forfeit?,
          column = Map.get(position, m.round),
          column != nil,
          numbers[m.team_a_id] && numbers[m.team_b_id] do
        %{type: "--", round: column, white: numbers[m.team_a_id], black: numbers[m.team_b_id]}
      end
    else
      []
    end
  end

  # TRF26's `362`: a team event's own match-point values - this app's
  # `team_match_points_win/draw/loss` (2/1/0 by default) - and, for a team
  # Swiss, `P`: the pairing-allocated bye's match points
  # (`Tournament.team_pab_value/2` - the tournament's own value, else a
  # draw's, C.04.6 Art. 1.4). `320` carries the same number with the bye's
  # game points; `P` is what a reader with no `320` falls back on. `A` (a
  # match lost by forfeit) is not written: this app scores such a match, a
  # double forfeit included, as an ordinary loss, which is the value a
  # reader with no `A` already uses (`PairingsEngine.TrfImport`).
  defp team_point_system(tournament, dialect) do
    if dialect == :trf26 and Tournament.team?(tournament) do
      base = %{
        win: tournament.team_match_points_win,
        draw: tournament.team_match_points_draw,
        loss: tournament.team_match_points_loss
      }

      if Tournament.team_swiss?(tournament) do
        {pab, _gp} = Tournament.team_pab_value(tournament, max(tournament.team_boards || 1, 1))
        Map.put(base, :pab, pab)
      else
        base
      end
    end
  end

  # TRF26's `320`: the team given the pairing-allocated bye each round of a
  # team Swiss, read back by `PairingsEngine.TeamMatchInference` without
  # guessing. Column position is round position in `rounds` (the file's own
  # round selection - "Two dialects"), not the tournament's round number, the
  # same compaction `filter_player_games/3` already applies to every player's
  # games; trailing rounds with no bye are dropped, same as `320`'s own
  # column count on a file this app reads.
  #
  # A team round robin's bye is the Berger bye, not a pairing-allocated one
  # (C.04.6 Art. 1.4 does not apply to it), so this app writes no `320` for
  # it. Nor does it ever write a `330`: a match this app forfeits by decision
  # (`PairingsEngine.TeamMatches.forfeit_match/3`) already has every board's
  # own forfeit result on the `001` lines, which is what a `330` is for a
  # match that has none of - so no match this app exports needs one.
  defp team_pab(tournament, rounds, dialect) do
    if dialect == :trf26 and Tournament.team_swiss?(tournament) do
      teams = Tournaments.list_teams(tournament.id)

      if teams != [] and Enum.all?(teams, & &1.pairing_number) do
        numbers = Map.new(teams, &{&1.id, &1.pairing_number})
        byes = Tournaments.team_byes_by_round(tournament.id)

        teams_by_round =
          rounds
          |> Enum.map(&(Map.get(byes, &1) |> then(fn id -> id && Map.get(numbers, id) end) || 0))
          |> Enum.reverse()
          |> Enum.drop_while(&(&1 == 0))
          |> Enum.reverse()

        {mp, gp} = Tournament.team_pab_value(tournament, max(tournament.team_boards || 1, 1))

        %{
          match_points: mp,
          game_points: Float.round(gp / 1, 1),
          teams: teams_by_round
        }
      end
    end
  end

  # `PairingsEngine.Build` is the one place that knows. This used to mirror
  # `PairingsEngineWeb.Layouts.app_version/0` under a comment saying the
  # duplication was deliberate to avoid reaching into the web layer - which
  # was the right instinct and the wrong fix: the answer belonged in neither.
  #
  # The RELEASE here, not the build id: this string goes into the TRF's
  # generator field, which a FIDE reader parses, and "0.18.0+3f2a1c9" is not
  # what that field is for.
  defp app_version, do: PairingsEngine.Build.version()

  # TRF26's `192`: which system paired the boards, in FIDE's own
  # `TournamentTypeCodeTable192-TRF26` vocabulary. JaVaFo implements the
  # Dutch system as it stood before 1 July 2025 (`FIDE_DUTCH_2017`) and
  # Ainalrami the edition in force since - the table's code for that is
  # `FIDE_DUTCH_2025` (`_BAKU` under Baku acceleration). Before 0.69.0 this
  # wrote `FIDE_DUTCH_2026`, a code FIDE's table has never had: the pinned
  # `Ainalrami.Trf.serialize/2` validates `192` against its own copy of the
  # table, which carried the same mistake until Ainalrami 0.33.0 put
  # `FIDE_DUTCH_2025` in its place. `TrfImport.system_attrs/1` still reads
  # `_2026` (and bare `FIDE_DUTCH`), so a file exported before the fix comes
  # back as Ainalrami. Keizer and the two match formats have no FIDE code and
  # are what the table calls CUSTOM.
  #
  # A team event's code names its colour rule and its primary/secondary
  # score, which this app always pairs the same way regardless of what an
  # arbiter chooses (Type A colour preferences, match points primary, game
  # points secondary - `Ainalrami.TeamPairing.Colour.first_team/4`,
  # `PairingsEngine.TeamSwiss`), so it is always `FIDE_TEAM_TYPEA_MP_GP`
  # (there is no OTHER code this app could honestly write). A team round
  # robin's cycle count is written the same way the individual one below is.
  defp tournament_type_code(t) do
    baku = if t.acceleration == "baku", do: "_BAKU", else: ""
    team? = t.type in ["team-swiss", "team-roundrobin"]

    cond do
      team? and t.pairing_system == "round_robin" -> "BERGER_TEAM_ROUNDROBIN_G#{t.rr_cycles || 1}"
      team? -> "FIDE_TEAM_TYPEA_MP_GP" <> baku
      t.pairing_system == "keizer" -> "CUSTOM_SWISS"
      t.pairing_system == "round_robin" and t.rr_match_format -> "CUSTOM_ROUNDROBIN"
      t.pairing_system == "round_robin" -> "BERGER_ROUNDROBIN_G#{t.rr_cycles || 1}"
      t.swiss_match_format -> "CUSTOM_SWISS"
      t.pairing_engine == "javafo" -> "FIDE_DUTCH_2017" <> baku
      true -> "FIDE_DUTCH_2025" <> baku
    end
  end

  # The configured tie-breaks in C.07's own spelling. Four of this app's
  # codes are spelt its own way (BHC1, BHC2, MBH, AROC1 for BH/C1, BH/C2,
  # BH/M1, ARO/C1 - `AinalramiBridge.codes/0`), and until 2026-10-02 they
  # went out as they were: a pairing checker reading the file could not
  # check its standings at all ("BHC1 is not a tie-break code"), and BHC1
  # leads the default Swiss list. Anything that is not a code shape is
  # dropped rather than let the writer refuse the file over it.
  #
  # A tournament paired as teams writes its codes in the C.07 spelling team
  # standings compute them under (`TeamStandings.c07_codes/0`: MP is MPTS,
  # BB is BC, SB is SB:MP ...). Until 2026-10-03 a team report carried the app's
  # own MP/GP/BB, which no checker reads, so `ainalrami -c` could not check
  # the standings of any team file.
  defp tie_break_codes(t) do
    c07 =
      if Tournament.paired_as_teams?(t),
        do: TeamStandings.c07_codes(),
        else: PairingsEngine.Standings.AinalramiBridge.codes()

    (t.tiebreaks || [])
    |> Enum.map(&String.upcase(to_string(&1)))
    |> Enum.map(&Map.get(c07, &1, &1))
    |> Enum.filter(&Regex.match?(~r"^[A-Z][A-Z0-9]*(:[A-Z]{2})?(/[A-Z0-9][A-Z0-9+.-]*)*$", &1))
  end

  defp initial_colour_code(tournament) do
    case Tournament.effective_initial_colour(tournament) do
      "white" -> "w"
      "black" -> "b"
      _ -> nil
    end
  end

  # 102: chief arbiter, as "<FIDE id> <name>" when the id is known (e.g.
  # "102 208418 Boutchon, Gaston"), else just the name. Skipped entirely
  # (nil) when the chief arbiter isn't known at all - `Trf.serialize/1`
  # already drops a nil/blank header line.
  defp chief_arbiter_line(tournament) do
    name = tournament.chief_arbiter || ""
    fide_id = officials(tournament)["chief_arbiter_fide_id"]

    cond do
      name == "" -> nil
      present?(fide_id) -> "#{fide_id} #{name}"
      true -> name
    end
  end

  # 112: one line per deputy/extra arbiter found among the officials map's
  # `deputyN_name` (N in 1..2 - FIDE only ever ranks 2 deputies by name) and
  # `arbiterN_name` (N in 1..extra_arbiters_count - everyone past that,
  # unranked - see `PairingsEngine.Tournaments.Tournament`'s `officials`
  # field docs and docs/norms.md's "Arbiters beyond chief + 2 deputies")
  # keys, same "<FIDE id> <name>" formatting as the chief arbiter. A slot
  # with no name set is skipped.
  defp deputy_arbiter_lines(tournament) do
    officials = officials(tournament)

    keys =
      Enum.map(1..2, &"deputy#{&1}") ++ Enum.map(extra_arbiter_range(officials), &"arbiter#{&1}")

    for key <- keys,
        name = officials["#{key}_name"],
        present?(name) do
      fide_id = officials["#{key}_fide_id"]
      if present?(fide_id), do: "#{fide_id} #{name}", else: name
    end
  end

  # 1..count is a *descending* range (iterating count..1) when count is 0 -
  # an easy footgun - so 0 (the common case: no extra arbiters) has to
  # short-circuit to an empty range explicitly.
  defp extra_arbiter_range(officials) do
    case extra_arbiters_count(officials) do
      n when n > 0 -> 1..n
      _ -> 1..0//1
    end
  end

  defp extra_arbiters_count(officials) do
    case officials["extra_arbiters_count"] do
      n when is_integer(n) -> n
      s when is_binary(s) -> s |> Integer.parse() |> extra_count_from_parse()
      _ -> 0
    end
  end

  defp extra_count_from_parse({n, _}), do: n
  defp extra_count_from_parse(:error), do: 0

  defp officials(tournament), do: tournament.officials || %{}

  defp present?(v), do: v not in [nil, ""]

  defp iso(nil), do: nil
  defp iso(%Date{} = date), do: Date.to_iso8601(date)

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  defp filter_player_games(player, rounds, tournament) do
    empty = %{opponent_rank: nil, colour: nil, result: nil}
    games = Enum.map(rounds, &Enum.at(player.games, &1 - 1, empty))

    %{player | games: games, points: Pairing.player_points(games, tournament)}
  end

  # A bye the arbiter has already granted for a round nobody has paired
  # yet. Everything else in the report is a record of rounds played; this
  # is the one forward-looking thing in it, and the reason it belongs here
  # is that the next round is the one somebody else may be pairing - from
  # this file. TRF26 carries it as a `240` record, the older spelling as
  # the `0000 - H` column an engine reads as "leave this player out"; both
  # come from the same game entry, which `Ainalrami.Trf.serialize/2` lifts
  # out again in the TRF26 dialect.
  #
  # Only on a full export. A `?rounds=1-3` slice is a historical excerpt
  # and says nothing about what comes next, and appending a future round to
  # one would put a column where the reader expects the file to end.
  defp append_future_byes(rows, tournament, rounds, paired) do
    if rounds == Enum.to_list(1..paired//1) do
      byes =
        tournament.id
        |> Tournaments.list_byes_from_round(paired + 1)
        |> Enum.group_by(& &1.player_id)

      Enum.map(rows, fn row ->
        Map.update!(row, :games, &(&1 ++ future_bye_games(byes, row, tournament)))
      end)
    else
      rows
    end
  end

  defp future_bye_games(byes, row, tournament) do
    case Map.get(byes, row.id, []) do
      [] ->
        []

      granted ->
        by_round = Map.new(granted, &{&1.round, &1})
        last = granted |> Enum.map(& &1.round) |> Enum.max()
        blank = %{opponent_rank: nil, colour: nil, result: nil}

        for round <- (length(row.games) + 1)..last//1 do
          case Map.get(by_round, round) do
            nil -> blank
            bye -> %{opponent_rank: nil, colour: nil, result: future_bye_code(bye, tournament)}
          end
        end
    end
  end

  # The letter for what the bye will be worth, as the played rounds are
  # written (`Pairing.unplayed_code/2`): an absence the tournament pays half
  # a point or a full one for is `H` or `F`. It was always `Z`, whatever it
  # paid.
  defp future_bye_code(bye, tournament),
    do: bye |> Standings.bye_points_for_row(tournament) |> Pairing.unplayed_code(tournament)

  # `players.extra_points` - the administrative bonus or penalty the
  # standings add on top of the game points (SWAR's "XtPts"). TRF's own
  # points column is game points by definition, so before this the bonus
  # left the building nowhere at all: a FIDE report and a re-import both
  # lost it silently. TRF26's untyped `299` record is exactly this, one per
  # distinct value with the players it applies to.
  defp free_point_records(players, tournament) do
    if tournament.count_extra_points do
      players
      |> Enum.filter(&(&1.pairing_number && (&1.extra_points || 0.0) != 0.0))
      |> Enum.group_by(& &1.extra_points, & &1.pairing_number)
      |> Enum.sort()
      |> Enum.map(fn {points, ranks} ->
        %{type: "", match_points: nil, points: points, round: nil, ranks: Enum.sort(ranks)}
      end)
    else
      []
    end
  end

  defp filter_round_dates(nil, _rounds), do: []
  defp filter_round_dates([], _rounds), do: []
  defp filter_round_dates(dates, rounds), do: Enum.map(rounds, &Enum.at(dates, &1 - 1))

  # FIDE wants a date for every round in the file, and one that arrives
  # without them comes back - after the event, when fixing it means
  # re-exporting and re-submitting rather than filling in a field. Refused
  # here instead, while it is still five minutes of work.
  #
  # Only for an export that CLAIMS rounds. A roster taken before the first
  # pairing has no rounds to date and is a perfectly good file - it is what an
  # arbiter checks a registration list against, and refusing it would make the
  # commonest pre-tournament export impossible. Same for `?rounds=1-3` of a
  # nine-round event: only those three rounds need dates, because only those
  # three are in the file.
  defp ensure_round_dates(tournament, rounds_spec) do
    paired = Pairing.paired_rounds_count(tournament.id)
    rounds = if is_list(rounds_spec), do: rounds_spec, else: parse_rounds(rounds_spec, paired)
    dates = tournament.round_dates || []

    case Enum.filter(rounds, &(Enum.at(dates, &1 - 1) in [nil, ""])) do
      [] ->
        :ok

      missing ->
        {:error,
         %ValidationError{
           message:
             "no date is set for #{describe_rounds(missing)}. FIDE requires a date for " <>
               "every round in the file. Set them under Settings, Dates."
         }}
    end
  end

  defp describe_rounds([n]), do: "round #{n}"
  defp describe_rounds(ns), do: "rounds " <> Enum.map_join(ns, ", ", &Integer.to_string/1)
end
