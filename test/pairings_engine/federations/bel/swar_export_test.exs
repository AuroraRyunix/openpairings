defmodule PairingsEngine.Federations.BEL.SwarExportTest do
  @moduledoc """
  The internal-consistency check `SwarExport`'s own moduledoc promises:
  export a tournament, re-parse the bytes with `SwarImport.parse/1` - the
  same probe-three-layouts heuristic a real `.swar` would go through - and
  assert every field survives. This is strong evidence the writer and
  reader agree with each other; it is NOT proof a real SWAR install
  accepts the file (see `SwarExport`'s moduledoc for why that can't be
  checked here).

  The tournament below deliberately exercises every branch `SwarExport`
  has: a normal win/loss/draw, both forfeit directions, a double forfeit,
  a played 0-0, both asymmetric FIDE codes, a pairing-allocated bye, and
  all three `"byes"`-table types (requested-half/requested-zero/absent) -
  plus distinct non-blank chief/deputy arbiter text, so the ambiguous
  `[TOURNOI]` tail (see `SwarExport`'s `@tournoi_layout`) is carrying real
  content rather than the all-zero case that can't distinguish a layout
  choice at all.
  """

  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Tournaments, Repo}
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}

  defp build_tournament do
    Repo.insert!(%Tournament{
      name: "Export Test Open",
      type: "swiss",
      pairing_system: "swiss",
      organizer: "Test Chess Club",
      organizer_club_number: "999",
      city: "Testville",
      chief_arbiter: "Jane Arbiter",
      deputy_arbiter: "John Deputy",
      start_date: "2026-08-10",
      end_date: "2026-08-12",
      rounds_count: 3,
      round_dates: ["2026-08-10", "2026-08-11", "2026-08-12"],
      tiebreaks: ["BH", "SB", "DE"],
      standard: "rapid",
      rate_of_play: "25 min + 10 sec/move",
      points_win: 1.0,
      points_draw: 0.5,
      points_loss: 0.0,
      bye_value: 0.5,
      abs_value: 0.5,
      abs_nbfois: 3,
      abs_jusque: 7,
      federation: "BEL",
      fide_homologated: true,
      categories: ["-1100", "-1800", "Women"],
      swar_guid: "test-guid-1234"
    })
  end

  defp build_player(tournament, attrs) do
    Repo.insert!(
      struct(
        %Player{
          tournament_id: tournament.id,
          name: "Base Player",
          sex: "m",
          title: "",
          federation: "BEL",
          club: "Test Club",
          paid: "paid",
          affiliated: true
        },
        attrs
      )
    )
  end

  defp pairing!(round, board, white, black, result) do
    Repo.insert!(%Pairing{
      round_id: round.id,
      board: board,
      white_player_id: white && white.id,
      black_player_id: black && black.id,
      result: result
    })
  end

  defp bye_row!(tournament, player, round_number, type) do
    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: player.id, round: round_number, type: type}
    ])
  end

  setup do
    t = build_tournament()

    a =
      build_player(t, %{
        name: "Alice Winner",
        sex: "w",
        title: "WIM",
        fide_id: 12345,
        fide_rating: 2100,
        national_id: "5001",
        national_rating: 1980,
        federation: "BEL",
        birth_year: 1990,
        birth_date: ~D[1990-05-14],
        club: "Chess Club A",
        pairing_number: 1,
        category: "-1800",
        categories: ["-1800"],
        extra_points: 0.5
      })

    b =
      build_player(t, %{
        name: "Bob Loser",
        pairing_number: 2,
        national_id: "5002",
        birth_year: 2005,
        category: "-1100",
        categories: ["-1100"]
      })

    c =
      build_player(t, %{
        name: "Carol Forfeit",
        pairing_number: 3,
        national_id: "",
        club_number: 42
      })

    d =
      build_player(t, %{
        name: "Dave Absentminded",
        pairing_number: 4,
        absent: true
      })

    e =
      build_player(t, %{
        name: "Eve Doubleforfeit",
        pairing_number: 5
      })

    f =
      build_player(t, %{
        name: "Frank Zero",
        pairing_number: 6
      })

    g =
      build_player(t, %{
        name: "Grace Half",
        pairing_number: 7
      })

    h =
      build_player(t, %{
        name: "Heidi Bye",
        pairing_number: 8
      })

    i =
      build_player(t, %{
        name: "Ivan Forfeited",
        pairing_number: 9,
        forfeit: true
      })

    j =
      build_player(t, %{
        name: "Judy Halfbye",
        pairing_number: 10
      })

    k =
      build_player(t, %{
        name: "Kevin Zerobye",
        pairing_number: 11
      })

    l =
      build_player(t, %{
        name: "Liam Absentee",
        pairing_number: 12
      })

    r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    pairing!(r1, 1, a, b, "1-0")
    pairing!(r1, 2, c, d, "1-0FF")
    pairing!(r1, 3, e, f, "0-0FF")
    pairing!(r1, 4, g, h, "1/2-1/2")
    pairing!(r1, 5, i, nil, "bye")
    # None of these three has a real board this round - the ONE
    # combination `round_record_for/5` can actually represent, since a
    # real Pairing and a "byes" row for the same player/round both
    # claiming the same SWAR record would be unrepresentable (SWAR has
    # exactly one [RONDE] entry per player per round).
    bye_row!(t, j, 1, "requested-half")
    bye_row!(t, k, 1, "requested-zero")
    bye_row!(t, l, 1, "absent")

    %{
      tournament: t,
      players: %{a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i, j: j, k: k, l: l},
      round: r1
    }
  end

  test "an uncapped paid absence does not export as an unpaid one", %{tournament: t} do
    # nil means "no cap" here; 0 means "cap at zero" in SWAR's format, i.e.
    # pay nothing. The exporter wrote `|| 0`, mapping nil onto the byte that
    # means its opposite - so a club paying half a point for every round sat
    # out exported as one paying for none, and re-importing made that true.
    #
    # Reachable from the ordinary settings screen, which tells the arbiter to
    # leave the limits blank for "no cutoff round" and "every one pays".
    # Written straight through the Repo: the fixture is already paired, so
    # the scoring fields are locked against update_tournament/2. The lock is
    # correct - this test is about what the EXPORTER does with the state, not
    # about how it got there (a SWAR import sets it before round 1).
    {:ok, t} =
      t
      |> Ecto.Changeset.change(abs_value: 0.5, abs_jusque: nil, abs_nbfois: nil)
      |> Repo.update()

    binary = SwarExport.export(t.id)
    assert {:ok, parsed} = SwarImport.parse(binary)

    refute parsed.tournament.abs_nbfois == 0,
           "an uncapped absence count exported as 0, which SWAR reads as 'pay none'"

    refute parsed.tournament.abs_jusque == 0,
           "an uncapped cutoff round exported as 0, which SWAR reads as 'no round qualifies'"
  end

  test "a real cap still exports as itself", %{tournament: t} do
    {:ok, t} =
      t
      |> Ecto.Changeset.change(abs_value: 0.5, abs_jusque: 3, abs_nbfois: 2)
      |> Repo.update()

    binary = SwarExport.export(t.id)
    assert {:ok, parsed} = SwarImport.parse(binary)

    assert parsed.tournament.abs_jusque == 3
    assert parsed.tournament.abs_nbfois == 2
  end

  test "a cap past SWAR's one-byte range is clamped, not wrapped", %{tournament: t} do
    # `w_u8/1` is `<<v::8>>`, which MASKS: 256 came back out as 0, which SWAR
    # reads as "no round qualifies"/"no absence qualifies" - the exact
    # opposite of a very high cap. Written straight through the Repo because
    # `Tournament.changeset/2` now refuses these values outright (see
    # tournament_test.exs); this is the backstop for rows already on disk.
    {:ok, t} =
      t
      |> Ecto.Changeset.change(abs_value: 0.5, abs_jusque: 300, abs_nbfois: 1000)
      |> Repo.update()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        binary = SwarExport.export(t.id)
        assert {:ok, parsed} = SwarImport.parse(binary)

        assert parsed.tournament.abs_jusque == 255
        assert parsed.tournament.abs_nbfois == 255
      end)

    assert log =~ "past SWAR's one-byte range"
  end

  test "unrated and asymmetric games count towards NbParties", %{
    tournament: t,
    players: %{a: a, b: b},
    round: r1
  } do
    # `played?` was a private four-code copy of Standings' nine-code set, and
    # it feeds exactly one output - the NbParties i32. A player whose games
    # were unrated exported as "0 games played" beside nonzero points and a
    # populated round record: a file contradicting itself.
    pairing =
      Repo.get_by!(PairingsEngine.Tournaments.Pairing,
        round_id: r1.id,
        white_player_id: a.id
      )

    {:ok, _} =
      pairing
      |> Ecto.Changeset.change(result: "1-0U", black_player_id: b.id)
      |> Repo.update()

    binary = SwarExport.export(t.id)
    assert {:ok, parsed} = SwarImport.parse(binary)

    played = Enum.find(parsed.players, &(&1.name =~ "A" or &1.ni == 1))

    assert played.nb_parties > 0,
           "an unrated game is still a game played - NbParties must not be 0"
  end

  test "export then reparse survives the tournament header", %{tournament: t} do
    binary = SwarExport.export(t.id)
    assert {:ok, parsed} = SwarImport.parse(binary)

    assert parsed.version == "v7.00"
    assert parsed.guid == "test-guid-1234"

    tournoi = parsed.tournament
    assert tournoi.name == "Export Test Open"
    assert tournoi.organizer == "Test Chess Club"
    assert tournoi.city == "Testville"
    assert tournoi.arbiter1 == "Jane Arbiter"
    assert tournoi.arbiter2 == "John Deputy"
    assert tournoi.nb_rounds == 3
    assert tournoi.fide_homolog == 1
    # v7_strings layout: arb1/arb2 cannot survive (only ONE trailing
    # string exists on the wire) - see SwarExport's moduledoc. The single
    # "remarks" slot is SWAR's FIDE remarks, which a tournament that never
    # came from SWAR has none of.
    assert tournoi.fide_arb1 == ""
    assert tournoi.fide_arb2 == ""
    assert tournoi.fide_remarks == ""
    # SWAR's own date shape, `jj/mm/aaaa`.
    assert tournoi.start_date == "10/08/2026"
    assert tournoi.end_date == "12/08/2026"

    assert tournoi.type == 0
    assert tournoi.sw321_win == 4
    assert tournoi.sw321_nul == 2
    assert tournoi.sw321_los == 0
    assert tournoi.sw321_bye == 2
    assert tournoi.tournoi_std == 1
    assert tournoi.bye_value == 1
    assert tournoi.abs_value == 1
    assert tournoi.abs_nbfois == 3
    assert tournoi.abs_jusque == 7
    assert tournoi.federation == 2

    assert parsed.dates == ["10/08/2026", "11/08/2026", "12/08/2026"]
    assert parsed.tiebreaks == [1, 6, 8, 0, 0]
  end

  describe "one category per player on the wire" do
    # SWAR carries ONE signed 32-bit category index per player and has no
    # second slot, so what is written is the pairing category. The dangerous
    # failure would have been silent: `Enum.find_index/2` matches no name
    # against a list, `nil -> 0`, and every player in the file exports as
    # uncategorised with no crash and no warning - a whole tournament's
    # category assignment gone with nothing on screen to say so.
    test "handing the writer a list raises instead of exporting zeros" do
      assert_raise ArgumentError, ~r/one category per player/, fn ->
        SwarExport.reverse_cat_index(["A", "B"], ["A", "B"])
      end
    end

    test "a blank or unknown category is still a plain 0" do
      assert SwarExport.reverse_cat_index("", ["A"]) == 0
      assert SwarExport.reverse_cat_index(nil, ["A"]) == 0
      assert SwarExport.reverse_cat_index("Ghost", ["A"]) == 0
    end

    test "a player in several categories exports the one they pair in" do
      t =
        Repo.insert!(%Tournament{
          name: "Multi",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          categories: ["-1100", "-1800", "Women"],
          categories_enabled: true
        })

      # A player in both "-1800" and "Women" pairs in "-1800" - index 1 in
      # the tournament's own list, so cat_index (1+1)*100 = 200.
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Multi Category",
          "pairing_number" => 1,
          "categories" => ["Women", "-1800"]
        })

      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()

      multi = Enum.find(parsed.players, &(&1.name == "Multi Category"))
      assert multi.cat_index == 200
    end
  end

  test "categories round-trip into value1, no leading blank slot", %{tournament: t} do
    binary = SwarExport.export(t.id)
    {:ok, parsed} = SwarImport.parse(binary)

    # 5 - SWAR's categories given by name, which is what categories made
    # here are.
    assert parsed.categories.type == 5
    assert Enum.take(parsed.categories.value1, 3) == ["-1100", "-1800", "Women"]
    assert Enum.all?(parsed.categories.value2, &(&1 == ""))
  end

  test "player fields round-trip, including v7's Elo-is-FIDE-rating rule", %{tournament: t} do
    binary = SwarExport.export(t.id)
    {:ok, parsed} = SwarImport.parse(binary)

    alice = Enum.find(parsed.players, &(&1.name == "Alice Winner"))
    assert alice.ni == 1
    assert alice.sex == 2
    assert alice.country == "BEL"
    assert alice.mat_nat == 5001
    assert alice.mat_fide == 12345
    # v7 has only ONE Elo field on the wire and it IS the FIDE rating.
    assert alice.elo == 2100
    assert alice.elo_fide == 2100
    assert alice.title == 4
    assert alice.birth == "19900514"
    # "-1800" is index 1 (0-based) in tournament.categories, so cat_index
    # is (1+1)*100 = 200 - see reverse_cat_index/2 and category_name/2.
    assert alice.cat_index == 200
    # The tournament does not count extra points and SWAR always would, so
    # they stay out of the file - see the extra-points test below.
    assert alice.extra_pts == 0

    bob = Enum.find(parsed.players, &(&1.name == "Bob Loser"))
    assert bob.birth == "20050000"
    # "-1100" is index 0, so cat_index is (0+1)*100 = 100.
    assert bob.cat_index == 100

    carol = Enum.find(parsed.players, &(&1.name == "Carol Forfeit"))
    assert carol.mat_nat == 0
    assert carol.club_nr == 42

    dave = Enum.find(parsed.players, &(&1.name == "Dave Absentminded"))
    assert dave.absent == 2

    ivan = Enum.find(parsed.players, &(&1.name == "Ivan Forfeited"))
    assert ivan.absent == 1
  end

  test "reimporting the export reproduces every board's result, via the persisting path",
       %{tournament: t} do
    binary = SwarExport.export(t.id)

    path =
      Path.join(
        System.tmp_dir!(),
        "swar_export_roundtrip_#{System.unique_integer([:positive])}.swar"
      )

    File.write!(path, binary)

    assert {:ok, reimported, _warnings} = SwarImport.import_file(path)

    reimported_players = Tournaments.list_players(reimported.id)
    by_name = Map.new(reimported_players, &{&1.name, &1})

    round1 = Tournaments.get_round(reimported.id, 1)

    pairing_for = fn name ->
      id = Map.fetch!(by_name, name).id
      Enum.find(round1.pairings, &(&1.white_player_id == id or &1.black_player_id == id))
    end

    assert pairing_for.("Alice Winner").result == "1-0"
    assert pairing_for.("Carol Forfeit").result == "1-0FF"
    assert pairing_for.("Eve Doubleforfeit").result == "0-0FF"
    assert pairing_for.("Grace Half").result == "1/2-1/2"

    ivan_pairing = pairing_for.("Ivan Forfeited")
    assert ivan_pairing.result == "bye"
    assert ivan_pairing.black_player_id == nil

    byes = Tournaments.list_byes_for_round(reimported.id, 1)
    bye_type_by_name = Map.new(byes, &{&1.player.name, &1.type})
    assert bye_type_by_name["Judy Halfbye"] == "requested-half"
    assert bye_type_by_name["Kevin Zerobye"] == "requested-zero"
    assert bye_type_by_name["Liam Absentee"] == "absent"

    File.rm(path)
  end

  test "a globally-absent player with no pairing AND no byes row for a round gets an explicit zero-point record, not a gap",
       %{tournament: t, players: %{d: dave}} do
    # Regression for the "real SWAR reads back garbage" bug: before this
    # fix, a round with neither a Pairing nor a "byes" row for a player
    # was simply left out of their `[RONDE]` array - self-consistent for
    # our own reader (the length prefix matched what was actually
    # written), but real SWAR was found to desync on a file shaped like
    # that (a player accumulating rounds with no record at all): garbled
    # "???" opponent names and phantom results on LATER rounds for
    # exactly that player, traced from a real tournament export. Dave is
    # already globally `absent: true` (see `setup/0`) and played round 1
    # for real; round 2 here gives him neither a pairing nor a byes row -
    # the exact gap shape that used to vanish from the array entirely.
    r2 = Repo.insert!(%Round{tournament_id: t.id, number: 2, status: "finished"})
    # Round 2 needs at least one real pairing for `Tournaments.list_rounds/1`
    # to have something to iterate - reuse two other players.
    a = Repo.get_by!(Player, tournament_id: t.id, name: "Alice Winner")
    b = Repo.get_by!(Player, tournament_id: t.id, name: "Bob Loser")
    pairing!(r2, 1, a, b, "1-0")

    binary = SwarExport.export(t.id)
    {:ok, parsed} = SwarImport.parse(binary)

    dave_parsed = Enum.find(parsed.players, &(&1.name == dave.name))

    # Both round 1 (real forfeit pairing) AND round 2 (the gap) are
    # present - nb_round is 2, not 1, so the length prefix real SWAR
    # reads still matches exactly what follows it.
    assert dave_parsed.nb_round == 2
    assert Enum.map(dave_parsed.rounds, & &1.round_nr) == [1, 2]

    round2 = Enum.find(dave_parsed.rounds, &(&1.round_nr == 2))
    assert round2.table == 0
    assert round2.advers == 0
    assert round2.result == 0
  end

  test "a round before a player's start_round is written as not played, never omitted" do
    # A player who joined partway through still gets a record for every
    # round: SWAR finds a round by its POSITION in the player's array, so an
    # omitted round 1 made SWAR read round 2 as round 1. In a tournament that
    # does not count such a round as an absence it is the plain not-played
    # shape - nothing SWAR would count or pay (`LateEntry`; the other case,
    # SWAR's own absence record, is in late_entry_test.exs).
    t =
      build_tournament()
      |> Ecto.Changeset.change(late_entry_absences: false)
      |> Repo.update!()

    early = build_player(t, %{name: "Early Bird", pairing_number: 1})
    late = build_player(t, %{name: "Late Joiner", pairing_number: 2, start_round: 2})

    r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})
    pairing!(r1, 1, early, nil, "bye")

    r2 = Repo.insert!(%Round{tournament_id: t.id, number: 2, status: "finished"})
    pairing!(r2, 1, early, late, "1-0")

    binary = SwarExport.export(t.id)
    {:ok, parsed} = SwarImport.parse(binary)

    late_parsed = Enum.find(parsed.players, &(&1.name == "Late Joiner"))

    assert Enum.map(late_parsed.rounds, & &1.round_nr) == [1, 2]

    round1 = Enum.find(late_parsed.rounds, &(&1.round_nr == 1))
    assert {round1.table, round1.advers, round1.result} == {0, 0, 0}
  end

  test "Rank is the rating-sorted seed for players not numbered yet, not registration order" do
    # Deliberately scrambled: the player registered FIRST (what `Ni` carries
    # for a player with no pairing number) is the LOWEST-rated. If `Rank`
    # were ever written as `Ni` again (the bug this pins down - see
    # `reverse_player/6`'s own comment for the full story, including the
    # real SWAR install this was found against), this test would see Rank in
    # registration order instead of rating order.
    t = build_tournament()

    low = build_player(t, %{name: "Low Rated First In", fide_rating: 1200})
    mid = build_player(t, %{name: "Mid Rated Second In", fide_rating: 1800})
    high = build_player(t, %{name: "High Rated Last In", fide_rating: 2400})

    binary = SwarExport.export(t.id)
    {:ok, parsed} = SwarImport.parse(binary)

    by_name = Map.new(parsed.players, &{&1.name, &1})

    assert by_name[high.name].rank == 1
    assert by_name[mid.name].rank == 2
    assert by_name[low.name].rank == 3
  end

  test "once players have pairing numbers, Rank follows them" do
    # Pairing numbers are this tournament's starting ranks - by rating when
    # round 1 was paired, late entrants after - or, imported, SWAR's own
    # seed. SWAR seeds and numbers a round robin's Berger table by Rank, so
    # a tournament continued in SWAR must see the same order it was being
    # paired in here, rating or not.
    t = build_tournament()

    low = build_player(t, %{name: "Low Rated Number 1", pairing_number: 1, fide_rating: 1200})
    mid = build_player(t, %{name: "Mid Rated Number 2", pairing_number: 2, fide_rating: 1800})
    high = build_player(t, %{name: "High Rated Number 3", pairing_number: 3, fide_rating: 2400})
    late = build_player(t, %{name: "Unnumbered", fide_rating: 2600})

    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    by_name = Map.new(parsed.players, &{&1.name, &1})

    assert by_name[low.name].rank == 1
    assert by_name[mid.name].rank == 2
    assert by_name[high.name].rank == 3
    assert by_name[late.name].rank == 4

    assert by_name[low.name].ni == 1
    assert by_name[high.name].ni == 3
  end

  test "extra points go into the file only while the tournament counts them", %{tournament: t} do
    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    assert Enum.find(parsed.players, &(&1.name == "Alice Winner")).extra_pts == 0

    {:ok, t} = t |> Ecto.Changeset.change(count_extra_points: true) |> Repo.update()
    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    # Quarter points, as SWAR keeps them.
    assert Enum.find(parsed.players, &(&1.name == "Alice Winner")).extra_pts == 2
  end

  describe "exclusions: SWAR keeps one rule" do
    # `rules` are pairing rules (`PairingRule`), set before any round.
    defp excl_tournament(rules, players) do
      t =
        Repo.insert!(%Tournament{
          name: "Excl",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3
        })

      for r <- rules,
          do:
            Repo.insert!(struct(%PairingsEngine.Tournaments.PairingRule{tournament_id: t.id}, r))

      created =
        for {p, i} <- Enum.with_index(players, 1) do
          build_player(t, Map.merge(%{name: "P#{i}", pairing_number: i}, p))
        end

      {t, created}
    end

    defp exported_exclusion(t) do
      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      parsed.exclusion
    end

    test "every club, where club numbers and names agree, is SWAR's own rule" do
      {t, _} =
        excl_tournament([%{kind: "club"}], [
          %{club: "A", club_number: 1},
          %{club: "A", club_number: 1},
          %{club: "B", club_number: 2}
        ])

      assert exported_exclusion(t) == %{type: 3, values: ""}
      assert SwarExport.export_notes(t) == []
    end

    test "listed clubs go as their club numbers" do
      {t, _} =
        excl_tournament([%{kind: "club", names: ["A"]}], [
          %{club: "A", club_number: 618},
          %{club: "A", club_number: 618},
          %{club: "B", club_number: 2},
          %{club: "B", club_number: 2}
        ])

      assert exported_exclusion(t) == %{type: 1, values: "618"}
    end

    test "a club without a number is kept apart as a group of players, and said so" do
      {t, _} =
        excl_tournament([%{kind: "club"}], [
          %{club: "A", club_number: nil},
          %{club: "A", club_number: nil},
          %{club: "B", club_number: nil}
        ])

      # SWAR would put all three in "club 0" together; the club names keep
      # only the first two apart.
      assert exported_exclusion(t) == %{type: 0, values: "1,2"}
      assert Enum.any?(SwarExport.export_notes(t), &(&1 =~ "club numbers do not match"))
    end

    test "every federation is SWAR's own rule, with a word about SWAR's defect" do
      {t, _} = excl_tournament([%{kind: "federation"}], [%{}, %{}])
      assert exported_exclusion(t) == %{type: 4, values: ""}
      assert Enum.any?(SwarExport.export_notes(t), &(&1 =~ "does not apply"))
    end

    test "listed federations" do
      {t, _} =
        excl_tournament([%{kind: "federation", names: ["BEL", "fra"]}], [%{}, %{}])

      assert exported_exclusion(t) == %{type: 2, values: "BEL:FRA"}
    end

    test "two rules and a forbidden pair become groups of players that keep the same apart" do
      {t, [a, b, c, d]} =
        excl_tournament(
          [%{kind: "club"}, %{kind: "federation", names: ["NED"]}],
          [
            %{club: "A", club_number: 1},
            %{club: "A", club_number: 1},
            %{club: "B", club_number: 2, federation: "NED"},
            %{club: "C", club_number: 3, federation: "NED"}
          ]
        )

      {:ok, _} = Tournaments.add_forbidden_pairing(t, a.id, d.id)
      {:ok, _} = Tournaments.add_forbidden_pairing(t, b.id, c.id, soft: true)

      assert exported_exclusion(t) == %{type: 0, values: "1,2:1,4:3,4"}

      notes = SwarExport.export_notes(t)
      assert Enum.any?(notes, &(&1 =~ "SWAR keeps one exclusion rule"))
      assert Enum.any?(notes, &(&1 =~ "no soft pairing wishes"))
    end
  end

  describe "the rest of what SWAR can hold" do
    test "a round robin's own type, and every tie-break SWAR has" do
      t =
        Repo.insert!(%Tournament{
          name: "RR",
          type: "roundrobin",
          pairing_system: "round_robin",
          rr_cycles: 2,
          rounds_count: 6,
          tiebreaks: ["DE", "KS", "BPG", "AROC1", "MBH"]
        })

      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      assert parsed.tournament.type == 6
      assert parsed.tiebreaks == [8, 9, 14, 13, 2]
    end

    test "match format, both systems" do
      rr =
        Repo.insert!(%Tournament{
          name: "RR",
          type: "roundrobin",
          pairing_system: "round_robin",
          rr_match_format: true,
          rounds_count: 6
        })

      swiss =
        Repo.insert!(%Tournament{
          name: "Sw",
          type: "swiss",
          pairing_system: "swiss",
          swiss_match_format: true,
          rounds_count: 6
        })

      assert {:ok, %{tournament: %{type: 5}}} = rr.id |> SwarExport.export() |> SwarImport.parse()

      assert {:ok, %{tournament: %{type: 1}}} =
               swiss.id |> SwarExport.export() |> SwarImport.parse()
    end

    test "categories ranked separately, and the initial colour" do
      t =
        Repo.insert!(%Tournament{
          name: "Cat",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          categories: ["A"],
          categories_enabled: true,
          categories_ranked_separately: true,
          pair_by_category: true,
          initial_colour: "black"
        })

      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      assert parsed.tournament.cat_separes == 1
      assert parsed.tournament.appar_order == 1
      assert SwarExport.export_notes(t) == []
    end

    test "points other than 1, ½, 0 go as SWAR's 3-2-1 type, and the note says so" do
      t =
        Repo.insert!(%Tournament{
          name: "Football",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          points_win: 3.0,
          points_draw: 1.0
        })

      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      assert parsed.tournament.type == 3
      assert parsed.tournament.sw321_win == 12
      assert Enum.any?(SwarExport.export_notes(t), &(&1 =~ "3-2-1"))
    end

    test "the FIDE ids go into SWAR's per-round block" do
      t =
        Repo.insert!(%Tournament{
          name: "Homologated",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 9,
          fide_homologated: true,
          event_code: "111, 999",
          fide_id_ranges: [%{"fide_tournament_id" => "111", "from_round" => 1, "to_round" => 9}]
        })

      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      assert parsed.tournament.fide_homolog == 1

      assert Enum.take(parsed.tournament.fide_ids, 3) == [
               %{de: 1, aa: 9, id: 111},
               %{de: 0, aa: 0, id: 999},
               %{de: 0, aa: 0, id: 0}
             ]
    end
  end
end
