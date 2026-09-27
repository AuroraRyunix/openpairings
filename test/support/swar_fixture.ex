defmodule PairingsEngine.SwarFixture do
  @moduledoc """
  Builds synthetic `.swar` files, every field settable, for tests that need
  a SWAR file with a particular feature in it - and compares two imported
  tournaments field by field (`snapshot/1`), for the import -> export ->
  import round trip (`swar_round_trip_test.exs`, and the same check run by
  hand over real files, which are never committed).

  The layout is `SwarImport`'s read order for a v6.78 file (`version:`
  anything from "v6.50" up to "v6.99"): sixteen categories, `Pts_Corr`,
  `EloFide`, four trailing FIDE strings. Everything not given is a blank or
  SWAR's own default.

  Games and byes are given per round, not per player record:

      build(%{
        players: [%{ni: 1, name: "A"}, %{ni: 2, name: "B"}, %{ni: 3, name: "C"}],
        games: [{1, 1, 1, 2, :white_wins}],
        byes: [{1, 3, :pab}]
      })

  and each player's `[RONDE]` records are made from them, one per round in
  which the player appears, in round order.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{ForbiddenPairing, Pairing, Tournament}

  defp w_str(s), do: <<byte_size(s)::little-signed-32, s::binary>>
  defp w_i32(n), do: <<n::little-signed-32>>
  defp w_i16(n), do: <<n::little-signed-16>>
  defp w_u8(n), do: <<n::8>>

  @win 0x4000
  @draw 0x2000
  @loss 0x1000
  @zero_zero 0x0400
  @win_bye 0x0040
  @draw_bye 0x0020
  @loss_bye 0x0010
  @zero_zero_ff 0x0008
  @win_ff 0x0004
  @loss_ff 0x0001
  @table_bye 0x1000
  @table_absent 0x4000

  @doc "A `.swar` binary from `opts` - see the moduledoc."
  def build(opts) do
    version = Map.get(opts, :version, "v6.78")
    nb_rounds = Map.get(opts, :nb_rounds, 3)
    players = Map.get(opts, :players, [])
    records = records(players, Map.get(opts, :games, []), Map.get(opts, :byes, []))
    t = Map.get(opts, :tournament, %{})
    g = fn key, default -> Map.get(t, key, default) end

    header = w_str(version) <> w_str(g.(:guid, "{FIXTURE-GUID}")) <> w_str(g.(:mac, ""))

    fide_ids =
      g.(:fide_ids, [])
      |> then(&(&1 ++ List.duplicate({0, 0, 0}, 16 - length(&1))))
      |> Enum.map_join("", fn {de, aa, id} -> w_i32(de) <> w_i32(aa) <> w_i32(id) end)

    tournoi =
      w_str("[TOURNOI]") <>
        w_str(g.(:name, "Fixture Open")) <>
        w_str(g.(:organizer, "Fixture Club")) <>
        w_str(g.(:club_or_logo, "999")) <>
        w_str(g.(:city, "Fixtureville")) <>
        w_str(g.(:arbiter1, "")) <>
        w_str(g.(:arbiter2, "")) <>
        w_str(g.(:start_date, "01/09/2026")) <>
        w_str(g.(:end_date, "03/09/2026")) <>
        w_i32(g.(:cadence, 0)) <>
        w_str(g.(:cadence_other, "")) <>
        w_i32(nb_rounds) <>
        w_i32(g.(:frbe_from, 0)) <>
        w_i32(g.(:frbe_to, 0)) <>
        w_i32(g.(:fide_from, 0)) <>
        w_i32(g.(:fide_to, 0)) <>
        w_i32(g.(:cat_separes, 0)) <>
        w_i32(g.(:elo_ou_pays, 1)) <>
        w_i32(g.(:fide_homolog, 0)) <>
        fide_ids <>
        w_str(g.(:fide_arb1, "")) <>
        w_str(g.(:fide_arb2, "")) <>
        w_str("") <>
        w_str(g.(:fide_remarks, "")) <>
        w_i32(g.(:type, 0)) <>
        w_i32(g.(:sw_elo_r1, 1)) <>
        w_i32(g.(:sw_amer_presence, 6)) <>
        w_i32(g.(:plusieurs, 0)) <>
        w_i32(g.(:first_table, 1)) <>
        Enum.map_join(g.(:sw321, [4, 2, 0, 4, 0, 0]), "", &w_i32/1) <>
        w_i32(g.(:elo_used, 1)) <>
        w_i32(g.(:tournoi_std, 0)) <>
        w_i32(g.(:tb_personel, 0)) <>
        w_i32(g.(:appar_order, 2)) <>
        w_i32(g.(:elo_equal, 1)) <>
        w_i32(g.(:bye_value, 0)) <>
        w_u8(g.(:abs_value, 0)) <>
        w_u8(g.(:abs_nbfois, 0)) <>
        w_u8(g.(:abs_jusque, 0)) <>
        w_u8(0) <>
        w_i32(g.(:ff_value, 2)) <>
        w_i32(g.(:federation, 2))

    dates =
      w_str("[DATES]") <>
        Enum.map_join(1..max(nb_rounds, 0)//1, "", fn r ->
          w_str(Enum.at(Map.get(opts, :dates, []), r - 1, "0#{r}/09/2026"))
        end)

    tiebreaks = Map.get(opts, :tiebreaks, [1, 4, 6, 7, 8])
    tie_break = w_str("[TIE_BREAK]") <> Enum.map_join(pad(tiebreaks, 5, 0), "", &w_i32/1)

    {excl_type, excl_values} = Map.get(opts, :exclusion, {-1, ""})
    exclusion = w_str("[EXCLUSION]") <> w_i32(excl_type) <> w_str(excl_values)

    {cat_type, value1, value2} = Map.get(opts, :categories, {0, [], []})

    categories =
      w_str("[CATEGORIES]") <>
        w_i32(cat_type) <>
        Enum.map_join(pad(value1, 17, ""), "", &w_str/1) <>
        Enum.map_join(pad(value2, 17, ""), "", &w_str/1)

    xtra =
      w_str("[XTRA_POINTS]") <>
        Enum.map_join(pad(Map.get(opts, :xtra_points, []), 4, {0, 0}), "", fn {pts, elo} ->
          w_i32(pts) <> w_i32(elo)
        end)

    joueurs =
      w_str("[JOUEURS]") <>
        w_i32(length(players)) <>
        Enum.map_join(players, "", &player(&1, Map.get(records, &1.ni, [])))

    header <>
      tournoi <>
      dates <>
      tie_break <> exclusion <> categories <> xtra <> joueurs <> Map.get(opts, :trailing, "")
  end

  defp pad(list, n, filler), do: list ++ List.duplicate(filler, max(n - length(list), 0))

  defp player(p, rounds) do
    g = fn key, default -> Map.get(p, key, default) end

    w_i32(g.(:class, 0)) <>
      w_str(g.(:name, "Player #{p.ni}")) <>
      w_i32(p.ni) <>
      w_i32(g.(:rank, p.ni)) <>
      w_i32(g.(:cat_index, 0)) <>
      w_str(g.(:birth, "19900101")) <>
      w_i32(g.(:sex, 1)) <>
      w_str(g.(:country, "BEL")) <>
      w_i32(g.(:mat_nat, 0)) <>
      w_i32(g.(:mat_fide, 0)) <>
      w_i32(g.(:affilie, 1)) <>
      w_i32(g.(:elo, 1500)) <>
      w_i32(g.(:elo_fide, g.(:elo, 1500))) <>
      w_i32(g.(:title, 0)) <>
      w_i32(g.(:club_nr, 0)) <>
      w_str(g.(:club, "")) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      Enum.map_join(1..5, "", fn _ -> w_i32(0) end) <>
      w_i32(0) <>
      w_i32(g.(:paye, 1)) <>
      w_i32(g.(:absent, 4)) <>
      w_str(g.(:absent_rondes, "")) <>
      w_i32(g.(:extra_pts, 0)) <>
      w_i32(0) <>
      w_i16(length(rounds)) <>
      w_i16(g.(:handy_table, 0)) <>
      w_str("[RONDE]") <>
      Enum.map_join(rounds, "", fn r ->
        w_i32(r.round_nr) <>
          w_i32(r.table) <>
          w_i32(r.advers) <>
          w_i32(r.result) <> w_i32(r.color) <> w_i32(0) <> w_i32(0)
      end)
  end

  # Per-player [RONDE] records, in round order, from the games and byes.
  #
  #   games: {round, table, white_ni, black_ni, outcome} - outcome one of
  #     :white_wins, :black_wins, :draw, :white_ff (white wins by forfeit),
  #     :black_ff, :double_ff, :zero_zero, :unplayed (no result yet)
  #   byes: {round, ni, kind} - :pab (pairing-allocated), :half, :zero,
  #     :absent (SWAR's TABLE_ABSENT), :unpaired (no table yet, table -1)
  defp records(_players, games, byes) do
    game_records =
      Enum.flat_map(games, fn {round, table, w, b, outcome} ->
        {rw, rb} = outcome_codes(outcome)

        [
          {w, %{round_nr: round, table: table, advers: b, result: rw, color: 1}},
          {b, %{round_nr: round, table: table, advers: w, result: rb, color: -1}}
        ]
      end)

    bye_records =
      Enum.map(byes, fn {round, ni, kind} ->
        {table, result} =
          case kind do
            :pab -> {@table_bye, @win_bye}
            :half -> {0, @draw_bye}
            :zero -> {0, @loss_bye}
            :absent -> {@table_absent, 0}
            :unpaired -> {-1, 0}
          end

        {ni, %{round_nr: round, table: table, advers: 0, result: result, color: 0}}
      end)

    (game_records ++ bye_records)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {ni, list} -> {ni, Enum.sort_by(list, & &1.round_nr)} end)
  end

  defp outcome_codes(:white_wins), do: {@win, @loss}
  defp outcome_codes(:black_wins), do: {@loss, @win}
  defp outcome_codes(:draw), do: {@draw, @draw}
  defp outcome_codes(:white_ff), do: {@win_ff, @loss_ff}
  defp outcome_codes(:black_ff), do: {@loss_ff, @win_ff}
  defp outcome_codes(:double_ff), do: {@zero_zero_ff, @zero_zero_ff}
  defp outcome_codes(:zero_zero), do: {@zero_zero, @zero_zero}
  defp outcome_codes(:unplayed), do: {0, 0}

  @doc "Writes `binary` to a fresh file under `dir` and returns the path."
  def write!(dir, binary, name \\ "fixture.swar") do
    path = Path.join(dir, "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, binary)
    path
  end

  ## ---------- comparing two tournaments ----------

  # Settings the export cannot carry and that therefore legitimately differ
  # between a SWAR file and its re-import: the file's own version string
  # (an export is always "v7.00"), and SWAR's two FIDE-arbiter strings,
  # which a v7 file has no place for.
  @settings_not_carried ~w(version fide_arb1 fide_arb2)

  # Tournament columns that are row bookkeeping, not the tournament.
  @tournament_skip ~w(id user_id inserted_at updated_at public_slug public_slug_minted_at
    public_slug_server public_slug_published_at head_snapshot_id swar_uploaded_at
    swar_published_at openresults_key openresults_claim handoff_token handoff_origin
    handed_off_at handed_off_to deleted_at archived_at logo_data logo_content_type
    tournament_players rounds players teams __meta__)a

  @player_fields ~w(name sex title fide_id fide_rating national_id national_rating federation
    birth_year birth_date club club_number pairing_number paid affiliated absent forfeit
    fixed_board special_table absent_rounds extra_points category categories start_round
    status)a

  @doc """
  Everything an imported tournament IS, keyed by pairing number rather than
  by row id, so two imports of the same event compare equal: the
  tournament's own columns (bar row bookkeeping, and the SWAR settings a v7
  file cannot carry), every player, every round with its boards and byes,
  and the forbidden pairs.
  """
  def snapshot(tournament_id) do
    t = Repo.get!(Tournament, tournament_id)
    players = Tournaments.list_players(tournament_id)
    pn = Map.new(players, &{&1.id, &1.pairing_number})

    tournament =
      t
      |> Map.from_struct()
      |> Map.drop(@tournament_skip)
      |> Map.update(:swar_settings, %{}, &Map.drop(&1 || %{}, @settings_not_carried))

    rounds =
      for round <- Tournaments.list_rounds(tournament_id) do
        pairings =
          from(p in Pairing, where: p.round_id == ^round.id)
          |> Repo.all()
          |> Enum.map(&{&1.board, pn[&1.white_player_id], pn[&1.black_player_id], &1.result})
          |> Enum.sort()

        byes =
          tournament_id
          |> Tournaments.list_byes_for_round(round.number)
          |> Enum.map(&{pn[&1.player_id], &1.type})
          |> Enum.sort()

        %{number: round.number, status: round.status, pairings: pairings, byes: byes}
      end

    forbidden =
      from(f in ForbiddenPairing, where: f.tournament_id == ^tournament_id)
      |> Repo.all()
      |> Enum.map(fn f ->
        [a, b] = Enum.sort([pn[f.player_a_id], pn[f.player_b_id]])
        {a, b, f.soft}
      end)
      |> Enum.sort()

    %{
      tournament: tournament,
      players:
        players
        |> Enum.map(&Map.take(&1, @player_fields))
        |> Enum.sort_by(&{&1.pairing_number, &1.name}),
      rounds: rounds,
      forbidden: forbidden
    }
  end

  @doc """
  Where two `snapshot/1`s differ, as `[{path, left, right}]` - `[]` when
  they are the same tournament.
  """
  def diff(a, b), do: diff(a, b, [])

  defp diff(a, b, path) when is_map(a) and is_map(b) and not is_struct(a) and not is_struct(b) do
    keys = Enum.uniq(Map.keys(a) ++ Map.keys(b))
    Enum.flat_map(keys, &diff(Map.get(a, &1), Map.get(b, &1), path ++ [&1]))
  end

  defp diff(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{x, y}, i} -> diff(x, y, path ++ [i]) end)
  end

  defp diff(a, a, _path), do: []
  defp diff(a, b, path), do: [{path, a, b}]
end
