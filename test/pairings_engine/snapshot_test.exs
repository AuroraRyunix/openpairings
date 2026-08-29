defmodule PairingsEngine.SnapshotTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Snapshot, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # Personal data deliberately loaded onto the fixture's players. Every one of
  # these strings must be missing from the encoded payload - see the
  # "no personal data" test, which is the point of the whole exercise.
  @email "ilse.de.vos@example.invalid"
  @national_id "BEL-19870142"
  @birth_date_iso "1987-04-02"
  @birth_year 1987

  # Round 4 is paired but never published. Two markers exist nowhere else in
  # the tournament, so their absence from the JSON is a direct check that the
  # round did not travel: its own date, and a result token used on no other
  # board.
  @unpublished_round_date "2026-03-04"
  @unpublished_round_result "0-1U"

  # The hidden board in round 3 carries a result used on no other board, for
  # the same reason.
  @hidden_board_result "0-0FF"

  describe "build/1 - the security boundary" do
    test "an unpublished round is absent from the payload, not flagged in it" do
      {tournament, _} = swiss_fixture()

      snapshot = Snapshot.build(tournament)
      json = Jason.encode!(snapshot)

      # Rounds 1, 2, 3 and 5 are published; 4 is paired but held back. The
      # published set is deliberately non-contiguous - a manual-mode arbiter
      # can publish out of order, and a `number <= latest_published` check
      # would wrongly ship round 4 just because round 5 is public.
      assert Enum.map(snapshot["rounds"], & &1["number"]) == [1, 2, 3, 5]

      refute Enum.any?(snapshot["rounds"], &(&1["number"] == 4))
      refute json =~ @unpublished_round_date
      refute json =~ @unpublished_round_result

      # And its results must not reach the standings either: `after_round` is
      # the longest contiguous published prefix, so round 5's published
      # results do not drag round 4's held-back ones in behind them.
      assert snapshot["standings"]["after_round"] == 3
    end

    test "a hidden board is absent from boards, players and results alike" do
      {tournament, players} = swiss_fixture()

      snapshot = Snapshot.build(tournament)
      json = Jason.encode!(snapshot)

      round3 = Enum.find(snapshot["rounds"], &(&1["number"] == 3))
      hidden_white = players[7].pairing_number
      hidden_black = players[10].pairing_number

      assert Enum.map(round3["boards"], & &1["board"]) == [1, 2, 3]

      refute Enum.any?(round3["boards"], &(&1["white"] == hidden_white))
      refute Enum.any?(round3["boards"], &(&1["black"] == hidden_black))
      refute json =~ @hidden_board_result
    end

    test "no personal data travels, however it is stored on the player" do
      {tournament, players} = swiss_fixture()

      # The fixture's player 1 carries every kind of personal data this app
      # holds, including an email in the free-form `norm_data` map - the one
      # place an email can live on a player today, and exactly what a naive
      # `Map.from_struct/1` would carry across.
      loaded = Repo.get!(Player, players[1].id)
      assert loaded.norm_data["email"] == @email
      assert loaded.national_id == @national_id
      assert loaded.birth_date == Date.from_iso8601!(@birth_date_iso)
      assert loaded.birth_year == @birth_year

      json = tournament |> Snapshot.build() |> Jason.encode!()

      refute json =~ @email
      refute json =~ @national_id
      refute json =~ @birth_date_iso
      refute json =~ to_string(@birth_year)

      # The key names too - a field published as `null` for this player would
      # still be published with a value for the next one.
      refute json =~ "email"
      refute json =~ "national_id"
      refute json =~ "birth"
      refute json =~ "norm_data"
      refute json =~ "sex"

      # The allowlist itself, asserted as a whole set rather than key by key:
      # a field added to `player_row/1` fails this until someone decides it
      # belongs in the contract.
      snapshot = Snapshot.build(tournament)

      for player <- snapshot["players"] do
        assert Map.keys(player) |> Enum.sort() ==
                 ~w(category club federation fide_id name no rating title)
      end
    end
  end

  describe "build/1 - the document" do
    test "the envelope and tournament section follow the contract" do
      {tournament, _} = swiss_fixture()

      snapshot = Snapshot.build(tournament)

      assert snapshot["schema"] == "openresults/snapshot"
      assert snapshot["version"] == 1
      assert snapshot["source"]["app"] == "openpairings"
      assert is_binary(snapshot["source"]["version"])
      assert {:ok, _, 0} = DateTime.from_iso8601(snapshot["published_at"])

      assert snapshot["tournament"] == %{
               "slug" => tournament.public_slug,
               "name" => "Gent Spring Open 2026",
               "city" => "Ghent",
               "federation" => "BEL",
               "start_date" => "2026-03-01",
               "end_date" => "2026-03-05",
               "rounds_count" => 5,
               "system" => "swiss",
               "arbiter" => "Jorian Burssens",
               "fide_rated" => true,
               "registration_open" => true,
               "listed" => true,
               "display" => %{
                 "rating" => true,
                 "title" => true,
                 "federation" => true,
                 "club" => true,
                 "category" => true,
                 "tiebreaks" => true,
                 "player_cards" => true
               }
             }
    end

    test "players are referenced by pairing number, never by database id" do
      {tournament, players} = swiss_fixture()

      snapshot = Snapshot.build(tournament)

      assert Enum.map(snapshot["players"], & &1["no"]) == Enum.to_list(1..10)

      # An unrated player publishes a null rating, not this app's internal 0.
      unrated = Enum.find(snapshot["players"], &(&1["no"] == players[10].pairing_number))
      assert unrated["rating"] == nil
      assert unrated["name"] == "Nguyễn, Thị Hà"

      # Every reference anywhere in the document is one of those numbers.
      nos = MapSet.new(snapshot["players"], & &1["no"])

      for round <- snapshot["rounds"] do
        for board <- round["boards"] do
          assert MapSet.member?(nos, board["white"])
          assert MapSet.member?(nos, board["black"])
        end

        for bye <- round["byes"], do: assert(MapSet.member?(nos, bye["player"]))
      end

      for row <- snapshot["standings"]["rows"], do: assert(MapSet.member?(nos, row["player"]))
    end

    test "the two legacy forfeit spellings are normalised on the way out" do
      {tournament, _} = swiss_fixture()

      snapshot = Snapshot.build(tournament)
      json = Jason.encode!(snapshot)

      assert result_at(snapshot, 1, 4) == "1-0FF"
      assert result_at(snapshot, 2, 3) == "0-1FF"

      refute json =~ "+--"
      refute json =~ "--+"
    end

    test "result tokens travel verbatim, and an unreported game is null" do
      {tournament, _} = swiss_fixture()

      snapshot = Snapshot.build(tournament)

      # Played-but-unrated, and the VCL.13 asymmetric result, both unflattened.
      assert result_at(snapshot, 1, 5) == "1-0U"
      assert result_at(snapshot, 3, 2) == "1/2-0"
      assert result_at(snapshot, 3, 3) == nil
    end

    test "byes carry both the arbiter's kind and its configured point value" do
      {tournament, players} = swiss_fixture()

      snapshot = Snapshot.build(tournament)

      round2 = Enum.find(snapshot["rounds"], &(&1["number"] == 2))

      assert round2["byes"] == [
               %{
                 "player" => players[4].pairing_number,
                 "kind" => "pairing-allocated",
                 "points" => 1.0
               },
               %{"player" => players[10].pairing_number, "kind" => "absent", "points" => 0.0}
             ]

      round3 = Enum.find(snapshot["rounds"], &(&1["number"] == 3))

      assert round3["byes"] == [
               %{"player" => players[6].pairing_number, "kind" => "half-point", "points" => 0.5},
               %{"player" => players[9].pairing_number, "kind" => "zero-point", "points" => 0.0}
             ]
    end

    test "a hand-set order is published AS one, not silently as a computed one" do
      {tournament, _} = swiss_fixture()

      assert Snapshot.build(tournament)["standings"]["manual_order"] == false

      {:ok, manual} = Tournaments.enable_manual_ranking(tournament)
      built = Snapshot.build(Tournaments.get_tournament!(manual.id))

      # The disclosure used to live only on this app's own public standings
      # page, which no longer exists. Publishing the arbiter's chosen ORDER
      # while dropping the fact that a person chose it is the exact failure
      # docs/manual-standings.md is written to prevent.
      assert built["standings"]["manual_order"] == true

      # And the rows are still a real ordering, not disturbed by the flag.
      assert Enum.map(built["standings"]["rows"], & &1["rank"]) == Enum.to_list(1..10)
    end

    test "standings arrive computed, ordered, with tiebreaks declared positionally" do
      {tournament, _} = swiss_fixture()

      standings = Snapshot.build(tournament)["standings"]

      assert standings["tiebreaks"] == [
               %{"code" => "BHC1", "label" => "Buchholz Cut-1"},
               %{"code" => "BH", "label" => "Buchholz"},
               %{"code" => "SB", "label" => "Sonneborn-Berger"},
               %{"code" => "PS", "label" => "Progressive score"}
             ]

      assert Enum.map(standings["rows"], & &1["rank"]) == Enum.to_list(1..10)

      for row <- standings["rows"] do
        assert length(row["tiebreaks"]) == 4
        assert Enum.all?(row["tiebreaks"], &is_number/1)
      end

      # Ranking is the arbiter's, already applied - the rows come down in
      # order and OpenResults never re-sorts them.
      points = Enum.map(standings["rows"], & &1["points"])
      assert points == Enum.sort(points, :desc)
    end

    test "a Keizer tournament publishes its own three columns and no tiebreaks" do
      {tournament, _} = keizer_fixture()

      snapshot = Snapshot.build(tournament)

      assert snapshot["tournament"]["system"] == "keizer"
      assert snapshot["standings"]["tiebreaks"] == []
      assert snapshot["standings"]["after_round"] == 2

      for row <- snapshot["standings"]["rows"] do
        assert Map.keys(row) |> Enum.sort() == ~w(category player points rank score value)
        assert is_number(row["value"])
        assert is_number(row["score"])
      end
    end
  end

  describe "the cross-repo contract fixtures" do
    @tag :snapshot_fixtures
    test "a real snapshot is written to the OpenResults fixture directory" do
      {swiss, _} = swiss_fixture()
      {keizer, _} = keizer_fixture()

      write_fixture!("snapshot_swiss.json", Snapshot.build(swiss))
      write_fixture!("snapshot_keizer.json", Snapshot.build(keizer))
    end
  end

  ## ---------- fixtures ----------

  # Nine rounds' worth of awkwardness in five: byes of three kinds, both
  # legacy forfeit spellings, an unrated result, an unreported game, an
  # unrated player, accented names throughout, a hidden board, a paired but
  # unpublished round, and a published round ABOVE the unpublished one.
  #
  # Deliberately built with plain `Repo.insert!` rather than the pairing
  # engine: this is a shape test, and the point is to hand the builder exactly
  # the awkward state an arbiter's database ends up in, including states the
  # ordinary write paths reach only by a longer route.
  defp swiss_fixture do
    tournament =
      Repo.insert!(%Tournament{
        name: "Gent Spring Open 2026",
        type: "swiss",
        pairing_system: "swiss",
        city: "Ghent",
        federation: "BEL",
        chief_arbiter: "Jorian Burssens",
        start_date: "2026-03-01",
        end_date: "2026-03-05",
        round_dates: ~w(2026-03-01 2026-03-02 2026-03-03 2026-03-04 2026-03-05),
        rounds_count: 5,
        tiebreaks: ~w(BHC1 BH SB PS),
        categories: ~w(A B),
        categories_enabled: true,
        fide_homologated: true,
        # Manual mode is the only one in which a round can be held back, and
        # therefore the only one in which withholding is testable at all.
        publish_mode: "manual",
        public_slug: "gent-spring-open-2026",
        # The cross-repo fixture built from this tournament is what every
        # OpenResults registration test reads, and since 2026-08-29 that
        # site gates its entry form on this flag. Open here so the fixture
        # exercises the form; OpenResults has its own test for the closed
        # case, which overrides this rather than needing a second fixture.
        registration_open: true
      })

    roster = [
      {1, "Müller, Jörg", "GM", 2601, "GER", 1_503_014, "SF Berlin", "A"},
      {2, "Đurić, Nikola", "IM", 2455, "SRB", 2_503_014, "ŠK Beograd", "A"},
      {3, "Ó Súilleabháin, Séamus", "FM", 2312, "IRL", 3_503_014, "Gonzaga CC", "A"},
      {4, "Łukasiewicz, Paweł", "", 2208, "POL", nil, "KSz Polonia", "A"},
      {5, "Vandenberghe, Françoise", "WFM", 2104, "BEL", 4_503_014, "KGSRL", "A"},
      {6, "Ștefănescu, Ioana", "WIM", 2033, "ROU", 5_503_014, "CS Universitatea", "B"},
      {7, "Ångström, Åsa", "", 1955, "SWE", nil, "Wasa SK", "B"},
      {8, "Björnsson, Sævar", "", 1866, "ISL", 6_503_014, "TR Reykjavík", "B"},
      {9, "De Smet, Jean-Baptiste", "", 1742, "BEL", nil, "Cercle d'Échecs", "B"},
      {10, "Nguyễn, Thị Hà", "", 0, "VIE", nil, "", "B"}
    ]

    players =
      for {no, name, title, rating, fed, fide_id, club, category} <- roster, into: %{} do
        player =
          Repo.insert!(%Player{
            tournament_id: tournament.id,
            pairing_number: no,
            name: name,
            title: title,
            fide_rating: rating,
            fide_id: fide_id,
            federation: fed,
            club: club,
            category: category,
            sex: if(no in [5, 6, 7, 10], do: "w", else: "m"),
            # The personal data the contract keeps out. Loaded onto every
            # player, not just one, so a leak of any single row is caught.
            national_id: @national_id,
            birth_year: @birth_year,
            birth_date: Date.from_iso8601!(@birth_date_iso),
            norm_data: %{"email" => @email, "title_claimed" => "IM"}
          })

        {no, player}
      end

    published = ~U[2026-03-01 14:00:00Z]

    r1 = insert_round(tournament, 1, published)
    r2 = insert_round(tournament, 2, published)
    r3 = insert_round(tournament, 3, published)
    # Paired, never published - the whole point of the withholding tests.
    r4 = insert_round(tournament, 4, nil)
    # Published ABOVE the held-back round, which manual mode allows.
    r5 = insert_round(tournament, 5, published)

    boards(r1, [
      {1, players[1], players[6], "1-0"},
      {2, players[7], players[2], "0-1"},
      {3, players[3], players[8], "1/2-1/2"},
      # Legacy single-sided forfeit spellings, still in SWAR-imported data.
      {4, players[9], players[4], "+--"},
      {5, players[5], players[10], "1-0U"}
    ])

    boards(r2, [
      {1, players[2], players[1], "1/2-1/2"},
      {2, players[6], players[3], "0-1"},
      {3, players[5], players[7], "--+"},
      {4, players[8], players[9], "0-1"}
    ])

    # A pairing-allocated bye: a real pairing row with one empty seat.
    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 5,
      white_player_id: players[4].id,
      black_player_id: nil,
      result: "bye"
    })

    boards(r3, [
      {1, players[1], players[3], "1-0"},
      {2, players[4], players[2], "1/2-0"},
      {3, players[8], players[5], ""}
    ])

    # The hidden board, with BOTH players still seated. `set_pairing_hidden/3`
    # only accepts a fully-vacated row today, so this state is written
    # directly - the builder must not be relying on that narrowness for its
    # guarantee, because the day the flag widens is not the day to discover
    # the payload was leaking seated boards all along.
    Repo.insert!(%Pairing{
      round_id: r3.id,
      board: 4,
      white_player_id: players[7].id,
      black_player_id: players[10].id,
      result: @hidden_board_result,
      hidden: true
    })

    boards(r4, [
      {1, players[1], players[2], "1-0"},
      {2, players[3], players[4], "0-1"},
      {3, players[5], players[6], @unpublished_round_result},
      {4, players[7], players[8], "1/2-1/2"},
      {5, players[9], players[10], "1-0"}
    ])

    boards(r5, [
      {1, players[2], players[1], "0-1"},
      {2, players[3], players[5], "1-0"},
      {3, players[4], players[6], "1/2-1/2"},
      {4, players[8], players[7], "1-0"},
      {5, players[10], players[9], "0-1"}
    ])

    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: players[10].id, round: 2, type: "absent"},
      %{tournament_id: tournament.id, player_id: players[6].id, round: 3, type: "requested-half"},
      %{tournament_id: tournament.id, player_id: players[9].id, round: 3, type: "requested-zero"}
    ])

    {tournament, players}
  end

  # A Keizer ladder, whose standings carry value/Keizer points/score instead
  # of FIDE tiebreak columns.
  defp keizer_fixture do
    tournament =
      Repo.insert!(%Tournament{
        name: "Cercle d'Échecs Gent - Winteravond 2026",
        type: "swiss",
        pairing_system: "keizer",
        city: "Ghent",
        federation: "BEL",
        chief_arbiter: "Jorian Burssens",
        start_date: "2026-01-08",
        end_date: "2026-01-22",
        round_dates: ~w(2026-01-08 2026-01-15 2026-01-22),
        rounds_count: 3,
        # Configured, and deliberately NOT published: a Keizer ladder does not
        # rank on them, so declaring them would promise columns the rows
        # cannot fill.
        tiebreaks: ~w(BH SB),
        publish_mode: "manual",
        public_slug: "cercle-gent-winteravond-2026"
      })

    roster = [
      {1, "Peeters, Wouter", 2088, "BEL"},
      {2, "Đoković, Milica", 1974, "SRB"},
      {3, "Hernández, José María", 1902, "ESP"},
      {4, "Van der Meché, Anouk", 1855, "NED"},
      {5, "Kowalczyk, Zofia", 1768, "POL"},
      {6, "Ó Braonáin, Cillian", 1690, "IRL"}
    ]

    players =
      for {no, name, rating, fed} <- roster, into: %{} do
        player =
          Repo.insert!(%Player{
            tournament_id: tournament.id,
            pairing_number: no,
            name: name,
            fide_rating: rating,
            federation: fed,
            club: "Cercle d'Échecs Gent",
            national_id: @national_id,
            birth_year: @birth_year,
            norm_data: %{"email" => @email}
          })

        {no, player}
      end

    published = ~U[2026-01-08 20:30:00Z]

    r1 = insert_round(tournament, 1, published)
    r2 = insert_round(tournament, 2, published)
    r3 = insert_round(tournament, 3, nil)

    boards(r1, [
      {1, players[1], players[4], "1-0"},
      {2, players[2], players[5], "1/2-1/2"},
      {3, players[3], players[6], "0-1"}
    ])

    boards(r2, [
      {1, players[6], players[1], "0-1"},
      {2, players[4], players[2], "1/2-1/2"},
      {3, players[5], players[3], "1-0"}
    ])

    boards(r3, [
      {1, players[1], players[5], "1-0"},
      {2, players[2], players[3], "1-0"},
      {3, players[6], players[4], "0-1"}
    ])

    {tournament, players}
  end

  defp insert_round(tournament, number, published_at) do
    Repo.insert!(%Round{
      tournament_id: tournament.id,
      number: number,
      status: "finished",
      published_at: published_at
    })
  end

  defp boards(round, rows) do
    for {board, white, black, result} <- rows do
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })
    end
  end

  defp result_at(snapshot, round_number, board_number) do
    snapshot["rounds"]
    |> Enum.find(&(&1["number"] == round_number))
    |> Map.fetch!("boards")
    |> Enum.find(&(&1["board"] == board_number))
    |> Map.fetch!("result")
  end

  ## ---------- cross-repo fixture output ----------

  # The OpenResults repo tests against these files, so they have to be real
  # output from this builder rather than something hand-written that agrees
  # with the contract on paper and with nothing in particular in practice.
  # Written only when that repo is actually checked out beside this one -
  # a clone without its sibling still runs every assertion above.
  defp write_fixture!(name, snapshot) do
    case fixture_dir() do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, name), Jason.encode!(snapshot, pretty: true) <> "\n")
    end
  end

  defp fixture_dir do
    case System.get_env("OPENRESULTS_FIXTURES") do
      nil ->
        sibling = Path.expand("../openresults", File.cwd!())
        if File.dir?(sibling), do: Path.join([sibling, "test", "fixtures"])

      configured ->
        configured
    end
  end

  test "a board with an unnumbered player is withheld, not emitted against a null" do
    # `publishable_players/1` drops a player with no `pairing_number`, because
    # a null `no` would be an unreferenceable row in `players`. Dropping the
    # player without dropping the BOARD they sit on trades that orphan for a
    # dangling reference, which is worse: the contract says every reference is
    # a `no` and nothing else identifies a player.
    {tournament, players} = swiss_fixture()
    unnumbered = Enum.find_value(players, fn {_no, p} -> p.pairing_number && p end)

    {:ok, _} =
      unnumbered
      |> Ecto.Changeset.change(%{pairing_number: nil})
      |> Repo.update()

    snapshot = Snapshot.build(PairingsEngine.Tournaments.get_tournament!(tournament.id))
    published = MapSet.new(snapshot["players"], & &1["no"])

    refute Enum.any?(snapshot["players"], &is_nil(&1["no"]))

    for round <- snapshot["rounds"], board <- round["boards"] do
      assert board["white"] in published,
             "board #{board["board"]} in round #{round["number"]} references an unpublished player"

      assert board["black"] in published
    end

    for round <- snapshot["rounds"], bye <- round["byes"] do
      assert bye["player"] in published
    end
  end
end
