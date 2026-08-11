defmodule PairingsEngine.SwarExportTest do
  @moduledoc """
  The internal-consistency check `SwarExport`'s own moduledoc promises:
  export a tournament, re-parse the bytes with `SwarImport.parse/1` — the
  same probe-three-layouts heuristic a real `.swar` would go through — and
  assert every field survives. This is strong evidence the writer and
  reader agree with each other; it is NOT proof a real SWAR install
  accepts the file (see `SwarExport`'s moduledoc for why that can't be
  checked here).

  The tournament below deliberately exercises every branch `SwarExport`
  has: a normal win/loss/draw, both forfeit directions, a double forfeit,
  a played 0-0, both asymmetric FIDE codes, a pairing-allocated bye, and
  all three `"byes"`-table types (requested-half/requested-zero/absent) —
  plus distinct non-blank chief/deputy arbiter text, so the ambiguous
  `[TOURNOI]` tail (see `SwarExport`'s `@tournoi_layout`) is carrying real
  content rather than the all-zero case that can't distinguish a layout
  choice at all.
  """

  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{SwarExport, SwarImport, Tournaments, Repo}
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
        extra_points: 0.5
      })

    b =
      build_player(t, %{
        name: "Bob Loser",
        pairing_number: 2,
        national_id: "5002",
        birth_year: 2005,
        category: "-1100"
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
    # None of these three has a real board this round — the ONE
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
    # string exists on the wire) — see SwarExport's moduledoc. Only the
    # single "remarks" slot (written from deputy_arbiter) comes back.
    assert tournoi.fide_arb1 == ""
    assert tournoi.fide_arb2 == ""
    assert tournoi.fide_remarks == "John Deputy"

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

    assert parsed.dates == ["2026-08-10", "2026-08-11", "2026-08-12"]
    assert parsed.tiebreaks == [1, 6, 8, 0, 0]
  end

  test "categories round-trip into value1, with the leading blank slot", %{tournament: t} do
    binary = SwarExport.export(t.id)
    {:ok, parsed} = SwarImport.parse(binary)

    assert parsed.categories.type == 1
    assert Enum.take(parsed.categories.value1, 4) == ["", "-1100", "-1800", "Women"]
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
    # is (1+1)*100 = 200 — see reverse_cat_index/2 and category_name/2.
    assert alice.cat_index == 200
    assert alice.extra_pts == 2

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

  test "Rank is the rating-sorted seed, not pairing_number/registration order" do
    # Deliberately scrambled: the LOWEST pairing_number (registration
    # order, what `Ni` carries) belongs to the LOWEST-rated player, and
    # vice versa. If `Rank` were ever written as `Ni` again (the bug
    # this pins down — see `reverse_player/5`'s own comment for the full
    # story, including the real SWAR install this was found against),
    # this test would see Rank in registration order instead of rating
    # order and fail on every assertion below.
    t = build_tournament()

    low = build_player(t, %{name: "Low Rated High Ni", pairing_number: 1, fide_rating: 1200})
    mid = build_player(t, %{name: "Mid Rated Mid Ni", pairing_number: 2, fide_rating: 1800})
    high = build_player(t, %{name: "High Rated Low Ni", pairing_number: 3, fide_rating: 2400})

    binary = SwarExport.export(t.id)
    {:ok, parsed} = SwarImport.parse(binary)

    by_name = Map.new(parsed.players, &{&1.name, &1})

    # Rating descending: High(2400) < Mid(1800) < Low(1200) in Rank order,
    # the OPPOSITE of their Ni/pairing_number order.
    assert by_name[high.name].rank == 1
    assert by_name[mid.name].rank == 2
    assert by_name[low.name].rank == 3

    # Ni still carries registration order, unaffected by this fix.
    assert by_name[low.name].ni == 1
    assert by_name[mid.name].ni == 2
    assert by_name[high.name].ni == 3
  end
end
