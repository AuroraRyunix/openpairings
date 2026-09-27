defmodule PairingsEngine.Federations.BEL.SwarTeamImportTest do
  @moduledoc """
  What a `.swar` file can say about a team competition, and what the import
  does with it (docs/swar-import.md, "Team competitions"):

    * SWAR's "team" mode - a Swiss named "... - team" - holds only the
      individual games, so it is refused as a team event and importable as
      an individual one on request;
    * a file that looks like no SWAR file seen so far (an unknown tournament
      type, data after the player list) is refused outright;
    * the [EXCLUSION] section - SWAR's "ICN style" team events - is carried
      over onto the club/federation rules and forbidden pairings.

  Synthetic binaries only, built field by field like the other SWAR tests'
  builders (`swar_import_pass2_test.exs`); no real file is read.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Tournaments.{ForbiddenPairing, Tournament}

  ## ---------- synthetic .swar binary builder ----------

  defp w_str(s), do: <<byte_size(s)::little-signed-32, s::binary>>
  defp w_i32(n), do: <<n::little-signed-32>>
  defp w_i16(n), do: <<n::little-signed-16>>
  defp w_u8(n), do: <<n::8>>

  # v6.40: FIDE-id block present (>= v5.24), no pre-v6.03 dummy, PreBye
  # present, 12 categories, `Paye` present (>= v5.52), no `PointsAdjusted`
  # (< v6.49) - so no points-mismatch notice joins the warnings under test.
  defp build_swar(opts) do
    name = Keyword.get(opts, :name, "Club Cup")
    type = Keyword.get(opts, :type, 0)
    {excl_type, excl_values} = Keyword.get(opts, :exclusion, {-1, ""})
    players = Keyword.get(opts, :players, default_players())
    nb_rounds = Keyword.get(opts, :nb_rounds, 1)
    trailing = Keyword.get(opts, :trailing, <<>>)

    header = w_str("v6.40") <> w_str("guid-#{System.unique_integer([:positive])}") <> w_str("")

    tournoi =
      w_str("[TOURNOI]") <>
        w_str(name) <>
        Enum.map_join(1..7, "", fn _ -> w_str("") end) <>
        w_i32(0) <>
        w_str("") <>
        w_i32(nb_rounds) <>
        Enum.map_join(1..7, "", fn _ -> w_i32(0) end) <>
        Enum.map_join(1..16, "", fn _ -> w_i32(0) <> w_i32(0) <> w_i32(0) end) <>
        Enum.map_join(1..4, "", fn _ -> w_str("") end) <>
        w_i32(type) <>
        Enum.map_join(1..9, "", fn _ -> w_i32(0) end) <>
        w_i32(0) <>
        Enum.map_join(1..6, "", fn _ -> w_i32(0) end) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_i32(0) <>
        w_i32(0)

    dates = w_str("[DATES]") <> Enum.map_join(1..nb_rounds, "", fn _ -> w_str("") end)
    tie_break = w_str("[TIE_BREAK]") <> Enum.map_join(1..5, "", fn _ -> w_i32(0) end)
    exclusion = w_str("[EXCLUSION]") <> w_i32(excl_type) <> w_str(excl_values)

    categories =
      w_str("[CATEGORIES]") <>
        w_i32(0) <> Enum.map_join(1..26, "", fn _ -> w_str("") end)

    xtra = w_str("[XTRA_POINTS]") <> Enum.map_join(1..4, "", fn _ -> w_i32(0) <> w_i32(0) end)

    joueurs =
      w_str("[JOUEURS]") <> w_i32(length(players)) <> Enum.map_join(players, "", &build_player/1)

    header <>
      tournoi <> dates <> tie_break <> exclusion <> categories <> xtra <> joueurs <> trailing
  end

  defp build_player(p) do
    rounds = Map.get(p, :rounds, [])

    w_i32(0) <>
      w_str(Map.get(p, :name, "Player #{p.ni}")) <>
      w_i32(p.ni) <>
      w_i32(p.ni) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_str(Map.get(p, :country, "BEL")) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(1) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(Map.get(p, :club_nr, 0)) <>
      w_str(Map.get(p, :club, "")) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      Enum.map_join(1..5, "", fn _ -> w_i32(0) end) <>
      w_i32(0) <>
      w_i32(1) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_i32(0) <>
      w_i16(length(rounds)) <>
      w_i16(0) <>
      w_str("[RONDE]") <>
      Enum.map_join(rounds, "", fn r ->
        w_i32(1) <>
          w_i32(r.table) <>
          w_i32(r.advers) <>
          w_i32(r.result) <>
          w_i32(r.color) <>
          w_i32(0) <> w_i32(0)
      end)
  end

  # Two boards of one round, a win and a loss each - the individual games a
  # team-mode file holds.
  defp default_players do
    [
      %{
        ni: 1,
        club_nr: 618,
        club: "Club A",
        rounds: [%{table: 1, advers: 3, result: 0x4000, color: 1}]
      },
      %{
        ni: 2,
        club_nr: 618,
        club: "Club A",
        rounds: [%{table: 2, advers: 4, result: 0x1000, color: -1}]
      },
      %{
        ni: 3,
        club_nr: 621,
        club: "Club B",
        rounds: [%{table: 1, advers: 1, result: 0x1000, color: -1}]
      },
      %{
        ni: 4,
        club_nr: 621,
        club: "Club B",
        rounds: [%{table: 2, advers: 2, result: 0x4000, color: 1}]
      }
    ]
  end

  defp write_swar!(dir, filename, opts) do
    path = Path.join(dir, filename)
    File.write!(path, build_swar(opts))
    path
  end

  defp tournament_count, do: Repo.aggregate(Tournament, :count)

  ## ---------- refused: a file unlike any SWAR file seen ----------

  describe "files this reader cannot be sure of" do
    @tag :tmp_dir
    test "data after the player list is left out, and the import says so", %{tmp_dir: dir} do
      path = write_swar!(dir, "cup.swar", trailing: w_str("[EQUIPES]") <> w_i32(2))
      before = tournament_count()

      assert {:ok, tournament, warnings} = SwarImport.import_file(path)
      warning = Enum.find(warnings, &(is_binary(&1) and &1 =~ "after the player list"))
      assert warning =~ "v6.40"
      assert warning =~ "imported without it"
      assert tournament_count() == before + 1
      assert length(Tournaments.list_players(tournament.id)) == 4

      assert {:ok, %{data: %{trailing_bytes: bytes}}} = SwarImport.prepare_import(path)
      assert bytes > 0
    end

    @tag :tmp_dir
    test "a tournament type outside SWAR's nine is refused, not read as a Swiss", %{tmp_dir: dir} do
      path = write_swar!(dir, "cup.swar", type: 9)

      assert {:error, message} = SwarImport.import_file(path)
      assert message =~ "type 9"
      assert {:error, _} = SwarImport.prepare_import(path)
    end

    @tag :tmp_dir
    test "every one of SWAR's own types still imports", %{tmp_dir: dir} do
      # 3 (3-2-1) has its own refusal; the others are SWAR's `TOURNOI_TYPE`.
      for type <- [0, 1, 2, 4, 5, 6, 7, 8] do
        path = write_swar!(dir, "type#{type}.swar", type: type)
        assert {:ok, _t, _w} = SwarImport.import_file(path), "type #{type}"
      end
    end

    test "the public norms tool, which reads players only, is not affected" do
      assert {:ok, {_t, players}} = SwarImport.build_structs(build_swar(type: 9))
      assert length(players) == 4
    end
  end

  ## ---------- SWAR's team mode ----------

  describe "SWAR's team mode (\" - team\")" do
    @tag :tmp_dir
    test "is refused as a team event, and imported as individual games on request", %{
      tmp_dir: dir
    } do
      path = write_swar!(dir, "r1.swar", name: "Interclubs 2026 - team")
      before = tournament_count()

      assert {:error, message} = SwarImport.import_file(path)
      assert message == SwarImport.team_marked_message()
      assert tournament_count() == before

      assert {:ok, t, _warnings} = SwarImport.import_file(path, nil, as_individual: true)
      t = Repo.preload(t, [:players, rounds: :pairings])
      assert t.type == "swiss"
      assert length(t.players) == 4
      assert [%{pairings: pairings}] = t.rounds
      assert length(pairings) == 2
    end

    @tag :tmp_dir
    test "prepare_import/2 flags it, and commit_import/3 refuses it until the flag is cleared",
         %{tmp_dir: dir} do
      path = write_swar!(dir, "upload-tmp", name: "Interclubs 2026 - team")

      assert {:ok, %{team_marked: true} = prepared} = SwarImport.prepare_import(path)
      assert {:error, _} = SwarImport.commit_import(prepared, %{})

      assert {:ok, %Tournament{}, _} =
               SwarImport.commit_import(%{prepared | team_marked: false}, %{})
    end

    @tag :tmp_dir
    test "the file name marks it too, as it does in SWAR", %{tmp_dir: dir} do
      path = write_swar!(dir, "upload-tmp", name: "Interclubs 2026")

      assert {:ok, %{team_marked: true}} =
               SwarImport.prepare_import(path, filename: "Interclubs 2026 - team.swar")

      assert {:ok, %{team_marked: false}} =
               SwarImport.prepare_import(path, filename: "Interclubs 2026.swar")
    end

    test "only as SWAR tests it: case-sensitive, and only for an ordinary Swiss" do
      marked? = fn opts, filename ->
        {:ok, data} = SwarImport.parse(build_swar(opts))
        SwarImport.team_marked?(data, filename)
      end

      assert marked?.([name: "Cup - team"], "cup.swar")
      refute marked?.([name: "Cup - Team"], "cup.swar")
      refute marked?.([name: "Cup team"], "cup.swar")
      # SWAR's `case SWISS:` only - a double Swiss named so is paired as usual.
      refute marked?.([name: "Cup - team", type: 1], "cup.swar")
      refute marked?.([name: "Cup", type: 1], "Cup - team.swar")
    end
  end

  ## ---------- [EXCLUSION]: "ICN style" team events ----------

  describe "the [EXCLUSION] section" do
    @tag :tmp_dir
    test "every club (3) keeps clubmates apart", %{tmp_dir: dir} do
      path = write_swar!(dir, "icn.swar", exclusion: {3, ""})
      assert {:ok, t, warnings} = SwarImport.import_file(path)
      assert t.club_exclusion == "all"
      assert t.fed_exclusion == "none"
      assert warnings == []
    end

    @tag :tmp_dir
    test "every nationality (4) keeps each federation apart", %{tmp_dir: dir} do
      path = write_swar!(dir, "nato.swar", exclusion: {4, ""})
      assert {:ok, t, _} = SwarImport.import_file(path)
      assert t.fed_exclusion == "all"
      assert t.club_exclusion == "none"
    end

    @tag :tmp_dir
    test "listed clubs (1) are listed by name, from SWAR's club numbers", %{tmp_dir: dir} do
      # 999 is nobody's club: it excludes nobody in SWAR either.
      path = write_swar!(dir, "listed.swar", exclusion: {1, "618:999"})
      assert {:ok, t, warnings} = SwarImport.import_file(path)
      assert t.club_exclusion == "listed"
      assert t.club_exclusion_list == "Club A"
      assert warnings == []
    end

    @tag :tmp_dir
    test "listed nationalities (2) are listed as federation codes", %{tmp_dir: dir} do
      path = write_swar!(dir, "listed-nat.swar", exclusion: {2, "FRA:ned"})
      assert {:ok, t, _} = SwarImport.import_file(path)
      assert t.fed_exclusion == "listed"
      assert t.fed_exclusion_list == "FRA, NED"
    end

    @tag :tmp_dir
    test "player groups (0) become forbidden pairings, every pair within a group", %{
      tmp_dir: dir
    } do
      # 7 is nobody's number and is skipped.
      path = write_swar!(dir, "pairs.swar", exclusion: {0, "1,2,3:4,7"})
      assert {:ok, t, _} = SwarImport.import_file(path)

      pairs =
        from(f in ForbiddenPairing,
          where: f.tournament_id == ^t.id,
          join: a in assoc(f, :player_a),
          join: b in assoc(f, :player_b),
          select: {a.pairing_number, b.pairing_number}
        )
        |> Repo.all()
        |> Enum.map(fn {a, b} -> Enum.sort([a, b]) end)
        |> Enum.sort()

      assert pairs == [[1, 2], [1, 3], [2, 3]]
      assert t.club_exclusion == "none"
    end

    @tag :tmp_dir
    test "no exclusion leaves every rule off", %{tmp_dir: dir} do
      path = write_swar!(dir, "plain.swar", [])
      assert {:ok, t, _} = SwarImport.import_file(path)
      assert {t.club_exclusion, t.fed_exclusion} == {"none", "none"}
    end

    @tag :tmp_dir
    test "a club spelled two ways under one number is carried over and flagged", %{
      tmp_dir: dir
    } do
      players =
        default_players()
        |> List.update_at(1, &%{&1 | club: "Club A."})

      path = write_swar!(dir, "icn.swar", exclusion: {3, ""}, players: players)
      assert {:ok, t, [warning]} = SwarImport.import_file(path)
      assert t.club_exclusion == "all"
      assert warning =~ "club number"
    end

    test "players without a club number are one club to SWAR, and that is flagged" do
      # SWAR's BuildAllClub formats ClubNr 0 as "000" like any other club,
      # so two club-less players never meet there; here a blank club is
      # never excluded.
      players = [
        %{ni: 1, club_nr: 0, club: "Paris"},
        %{ni: 2, club_nr: 0, club: "Lille"}
      ]

      {:ok, data} = SwarImport.parse(build_swar(exclusion: {3, ""}, players: players))
      assert [_warning] = SwarImport.exclusion_warnings(data)
    end
  end
end
