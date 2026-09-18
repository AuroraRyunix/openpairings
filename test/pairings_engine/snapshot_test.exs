defmodule PairingsEngine.SnapshotTest do
  use PairingsEngine.DataCase, async: true

  import PairingsEngine.SnapshotFixtures,
    only: [
      swiss_fixture: 0,
      keizer_fixture: 0,
      team_snapshot_fixture: 0,
      insert_round: 3,
      insert_round: 4,
      boards: 2
    ]

  alias PairingsEngine.{Repo, Snapshot, SnapshotFixtures, Tournaments}
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
      # the longest contiguous prefix of rounds both published AND complete,
      # so round 5's published results do not drag round 4's held-back ones
      # in behind them. It stops at 2 rather than 3 for a second, independent
      # reason: round 3's own board 3 has no result yet (see
      # `result_at(snapshot, 3, 3) == nil` below) - a published-but-incomplete
      # round stops the count exactly like an unpublished one does.
      assert snapshot["standings"]["after_round"] == 2
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
                 ~w(categories category club federation fide_id name no rating title)
      end
    end
  end

  describe "standings_through - withholding the roster before round 1" do
    defp roster_tournament(attrs) do
      tournament =
        Repo.insert!(
          struct(
            %Tournament{
              name: "Roster",
              type: "swiss",
              pairing_system: "swiss",
              rounds_count: 3,
              publish_mode: "manual",
              public_slug: "roster-#{System.unique_integer([:positive])}"
            },
            attrs
          )
        )

      for {no, name} <- [{1, "Alice"}, {2, "Bob"}] do
        Repo.insert!(%Player{tournament_id: tournament.id, pairing_number: no, name: name})
      end

      tournament
    end

    test "withheld when standings_through is nil and no round has published yet" do
      tournament = roster_tournament(%{standings_through: nil})

      snapshot = Snapshot.build(tournament)

      assert snapshot["players"] == []
      assert snapshot["rounds"] == []
      assert snapshot["standings"]["rows"] == []
      assert snapshot["standings"]["after_round"] == 0
    end

    test "shown when nothing is published, but standings_through is 0 (the default)" do
      tournament = roster_tournament(%{})

      snapshot = Snapshot.build(tournament)

      assert length(snapshot["players"]) == 2
    end

    test "shown once any round is published, regardless of standings_through" do
      tournament = roster_tournament(%{standings_through: nil})

      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: ~U[2026-01-01 00:00:00Z]
      })

      snapshot = Snapshot.build(Tournaments.get_tournament!(tournament.id))

      # By this point the round names these same players on its own boards
      # (once any are paired) - withholding the roster here would leave a
      # snapshot that is internally inconsistent, not merely sparse.
      assert length(snapshot["players"]) == 2
    end

    # The case the tests above never had: before round 1 is paired NOBODY has
    # a start number (they are issued by pairing), and the roster used to be
    # filtered down to nothing - a blank public page on a live tournament.
    defp unnumbered_tournament(attrs) do
      tournament =
        Repo.insert!(
          struct(
            %Tournament{
              name: "Unnumbered",
              type: "swiss",
              pairing_system: "swiss",
              rounds_count: 3,
              publish_mode: "manual",
              public_slug: "unnumbered-#{System.unique_integer([:positive])}"
            },
            attrs
          )
        )

      for {name, rating, status} <- [
            {"Carol", 1500, "active"},
            {"Bob", 1900, "active"},
            {"Alice", 1900, "active"},
            {"Walter", 2400, "withdrawn"}
          ] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          fide_rating: rating,
          status: status
        })
      end

      tournament
    end

    test "before round 1 is paired, the field is numbered provisionally in pairing order" do
      tournament = unnumbered_tournament(%{})

      snapshot = Snapshot.build(tournament)

      # Highest rating first, name as the tie-break; a withdrawn player is not
      # part of the field pairing will number, so not part of this list.
      assert Enum.map(snapshot["players"], &{&1["no"], &1["name"]}) ==
               [{1, "Alice"}, {2, "Bob"}, {3, "Carol"}]

      assert snapshot["standings"]["after_round"] == 0
      assert length(snapshot["standings"]["rows"]) == 3
    end

    test "the provisional numbers are the ones pairing round 1 then issues" do
      tournament = unnumbered_tournament(%{})
      provisional = Map.new(Snapshot.build(tournament)["players"], &{&1["name"], &1["no"]})

      PairingsEngine.Pairing.ensure_pairing_numbers(
        tournament,
        PairingsEngine.Pairing.active_players(tournament.id)
      )

      issued =
        tournament.id
        |> Tournaments.list_players()
        |> Enum.filter(& &1.pairing_number)
        |> Map.new(&{&1.name, &1.pairing_number})

      assert issued == provisional
    end

    test "standings_through nil withholds the provisional list too" do
      tournament = unnumbered_tournament(%{standings_through: nil})

      assert Snapshot.build(tournament)["players"] == []
    end

    # Reported 2026-09-18 on a live tournament: 21 on the roster, 3 absent, so
    # 18 belong on the public page - and it showed 16. The two missing were
    # registered AFTER round 1 was numbered, so they had no number yet, and a
    # roster with any numbers at all took only the numbered rows. A late entrant
    # is part of the field from the moment they are on it; they are numbered
    # provisionally here, exactly as the whole field is before round 1.
    test "a player registered after numbering is published with the number pairing will issue" do
      tournament = unnumbered_tournament(%{})

      PairingsEngine.Pairing.ensure_pairing_numbers(
        tournament,
        PairingsEngine.Pairing.active_players(tournament.id)
      )

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Dora",
        fide_rating: 2200,
        status: "active"
      })

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Eve",
        fide_rating: 1000,
        status: "active",
        absent: true
      })

      snapshot = Snapshot.build(tournament)

      # The three numbered players keep their frozen numbers; Dora - the only
      # active newcomer - continues after the highest number ever issued, and
      # the absent one is not part of the field at all.
      assert Enum.map(snapshot["players"], &{&1["no"], &1["name"]}) ==
               [{1, "Alice"}, {2, "Bob"}, {3, "Carol"}, {4, "Dora"}]

      # And the same number is the one pairing then issues for real.
      PairingsEngine.Pairing.ensure_pairing_numbers(
        tournament,
        PairingsEngine.Pairing.active_players(tournament.id)
      )

      assert Repo.get_by!(Player, tournament_id: tournament.id, name: "Dora").pairing_number == 4
    end
  end

  describe "effective standings through the snapshot (2026-09-11 publish model)" do
    defp floor_fixture(publish_mode \\ "manual") do
      tournament =
        Repo.insert!(%Tournament{
          name: "Floor",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 4,
          publish_mode: publish_mode,
          public_slug: "floor-#{System.unique_integer([:positive])}"
        })

      [a, b] =
        for no <- 1..2 do
          Repo.insert!(%Player{tournament_id: tournament.id, pairing_number: no, name: "P#{no}"})
        end

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      r1 = insert_round(tournament, 1, now)
      boards(r1, [{1, a, b, "1-0"}])

      r2 = insert_round(tournament, 2, now)
      boards(r2, [{1, b, a, "1-0"}])

      {Tournaments.get_tournament!(tournament.id), a, b}
    end

    test "rule 1: round 2's own pairings being public floors standings at round 1, with no explicit standings publish" do
      {tournament, _a, _b} = floor_fixture()

      snapshot = Snapshot.build(tournament)

      assert snapshot["standings"]["after_round"] == 1
      assert Enum.map(snapshot["rounds"], & &1["number"]) == [1, 2]
    end

    test "the rows are the standings after that round, not the latest results under its label" do
      # `after_round` alone is only a heading. Round 2 is complete and its
      # sheet is public, but standings after round 2 are not: the rows must
      # still be the table after round 1. Computed over every result, they
      # would publish round 2's outcome under "after round 1".
      {tournament, a, b} = floor_fixture()

      snapshot = Snapshot.build(tournament)
      points = Map.new(snapshot["standings"]["rows"], &{&1["player"], &1["points"]})

      assert snapshot["standings"]["after_round"] == 1
      assert points == %{a.pairing_number => 1.0, b.pairing_number => 0.0}
    end

    test "rule 2: an explicit publish_standings_through/2 call reaches the snapshot exactly" do
      {tournament, _a, _b} = floor_fixture()

      {:ok, tournament} = Tournaments.publish_standings_through(tournament, 2)

      assert Snapshot.build(tournament)["standings"]["after_round"] == 2
    end

    test "rule 8: immediate mode ignores standings_through and always shows the complete prefix" do
      {tournament, _a, _b} = floor_fixture("immediate")
      tournament = Ecto.Changeset.change(tournament, standings_through: nil) |> Repo.update!()

      snapshot = Snapshot.build(tournament)

      assert snapshot["standings"]["after_round"] == 2
      assert snapshot["players"] != []
    end

    test "round 0 default: a fresh tournament with no rounds shows the roster public, standings after round 0" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Fresh",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          publish_mode: "manual",
          public_slug: "fresh-#{System.unique_integer([:positive])}"
        })

      Repo.insert!(%Player{tournament_id: tournament.id, pairing_number: 1, name: "Solo"})

      snapshot = Snapshot.build(tournament)

      assert snapshot["standings"]["after_round"] == 0
      assert length(snapshot["players"]) == 1
    end
  end

  describe "several categories per player" do
    # `snapshot-schema.md` is additive only: `players[].category` is read by
    # every already-published tournament, so it keeps meaning "this player's
    # single category" and the set arrives beside it under a new key.
    test "category stays the single pairing category and categories carries the set" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Tags",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          categories: ["Open", "Women"],
          categories_enabled: true,
          public_slug: "tags"
        })

      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Both",
          "categories" => ["Women", "Open"],
          "pairing_number" => 1
        })

      {:ok, _} =
        Tournaments.create_player(tournament.id, %{"name" => "Neither", "pairing_number" => 2})

      players =
        tournament.id
        |> Tournaments.get_tournament!()
        |> Snapshot.build()
        |> Map.fetch!("players")
        |> Map.new(&{&1["name"], &1})

      both = players["Both"]
      # Ordered by the tournament's own list, not the order they were stored.
      assert both["categories"] == ["Open", "Women"]
      assert both["category"] == "Open"

      neither = players["Neither"]
      assert neither["categories"] == []
      assert neither["category"] == nil
    end

    test "tournament.categories carries the tournament's own vocabulary, in order" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Tags",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          categories: ["U1800", "Women", "U14"],
          categories_enabled: true,
          public_slug: "tags2"
        })

      snapshot = Snapshot.build(tournament)

      assert snapshot["tournament"]["categories"] == ["U1800", "Women", "U14"]
    end

    test "hiding the category display key omits both new fields, and leaves category alone" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Tags",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          categories: ["Open", "Women"],
          categories_enabled: true,
          public_slug: "tags3"
        })

      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Both",
          "categories" => ["Women", "Open"],
          "pairing_number" => 1
        })

      {:ok, hidden} =
        Tournaments.set_public_display(tournament, %{all_shown() | "category" => "false"})

      snapshot = Snapshot.build(hidden)

      refute Map.has_key?(snapshot["tournament"], "categories")

      player = snapshot["players"] |> Enum.find(&(&1["name"] == "Both"))
      refute Map.has_key?(player, "categories")
      # `category` - the single pairing category - keeps travelling: hiding
      # the display key is about grouping/filtering by category in public,
      # not about withholding the pairing partition, and it was never gated
      # before this change.
      assert player["category"] == "Open"
    end
  end

  describe "build/1 - the publisher field (2026-09-14)" do
    test "absent when the tournament has no owner" do
      {tournament, _} = swiss_fixture()
      refute Map.has_key?(Snapshot.build(tournament), "publisher")
    end

    test "carries the owner's email and this instance's host when hosted and the owner is known" do
      {tournament, _} = swiss_fixture()

      user =
        Repo.insert!(%PairingsEngine.Accounts.User{
          email: "jan.peeters@example.invalid",
          hashed_password: "x"
        })

      tournament = Repo.update!(Ecto.Changeset.change(tournament, user_id: user.id))

      snapshot = Snapshot.build(tournament)

      assert snapshot["publisher"] == %{
               "email" => "jan.peeters@example.invalid",
               "host" => PairingsEngineWeb.Endpoint.host()
             }
    end

    test "omitted in local mode, even when the owner is known" do
      {tournament, _} = swiss_fixture()

      user =
        Repo.insert!(%PairingsEngine.Accounts.User{
          email: "jan.peeters@example.invalid",
          hashed_password: "x"
        })

      tournament = Repo.update!(Ecto.Changeset.change(tournament, user_id: user.id))

      previous = Application.get_env(:pairings_engine, :local_mode, false)
      Application.put_env(:pairings_engine, :local_mode, true)

      try do
        refute Map.has_key?(Snapshot.build(tournament), "publisher")
      after
        Application.put_env(:pairings_engine, :local_mode, previous)
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
               "deputy" => nil,
               "time_control" => nil,
               "tempo" => "standard",
               "match_format" => false,
               "fide_rated" => true,
               "registration_open" => true,
               "listed" => true,
               "display" => PairingsEngine.PublicDisplay.resolve(nil),
               "categories" => ~w(A B)
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

      # Rounds 1 and 2 are published (round 3 is not), but nobody has
      # explicitly published STANDINGS for either - under the 2026-09-11
      # publish model, round 2's own pairings being public only guarantees
      # "at least round 1" (rule 1: `effective_standings_through/1` floors
      # at "contiguous published pairings - 1"), not round 2's own results.
      assert snapshot["standings"]["after_round"] == 1

      for row <- snapshot["standings"]["rows"] do
        assert Map.keys(row) |> Enum.sort() == ~w(category player points rank score value)
        assert is_number(row["value"])
        assert is_number(row["score"])
      end
    end
  end

  describe "board numbers the hall would recognise" do
    test "publishes the arbiter's label and the arbiter's order, not the raw column" do
      {tournament, _} = swiss_fixture()
      round = Repo.one!(from r in Round, where: r.tournament_id == ^tournament.id, limit: 1)

      # A fixed-table player: their board is renumbered to 1001 and moved to
      # the end, and the boards after them close the gap they left. This is
      # what the arbiter's screen and the printed sheet show.
      [first | _] = Repo.all(from p in Pairing, where: p.round_id == ^round.id, order_by: p.board)

      Repo.update_all(
        from(p in Pairing, where: p.id == ^first.id),
        set: [display_board: "1001", display_special: true]
      )

      boards = Snapshot.build(Tournaments.get_tournament!(tournament.id))["rounds"]
      boards = boards |> Enum.find(&(&1["number"] == round.number)) |> Map.fetch!("boards")

      # The real column still travels - a result is keyed on it.
      assert Enum.any?(boards, &(&1["board"] == first.board))

      # And so does the label, which is the thing printed in the hall. Before
      # this, the public page showed the raw column: board 1001 for a game
      # printed as board 12, and every board after it off by one.
      special = Enum.find(boards, &(&1["board"] == first.board))
      assert special["label"] == "1001"

      # Order too, because the order is half of the disagreement: a special
      # board sorts below the ordinary ones.
      assert List.last(boards)["label"] == "1001"
    end

    test "an ordinary board's label is just its number" do
      {tournament, _} = swiss_fixture()

      board = Snapshot.build(tournament)["rounds"] |> hd() |> Map.fetch!("boards") |> hd()

      assert board["label"] == to_string(board["board"])
    end
  end

  describe "a hand-set order that has stopped being true" do
    test "an ordinary manual order is disclosed, and not flagged as wrong" do
      {tournament, _} = swiss_fixture()
      {:ok, manual} = Tournaments.enable_manual_ranking(tournament)

      standings = Snapshot.build(Tournaments.get_tournament!(manual.id))["standings"]

      assert standings["manual_order"] == true
      assert standings["manual_stale"] == false
      assert standings["manual_incomplete"] == false
    end

    test "a result entered after the order was set marks it stale" do
      {tournament, _} = swiss_fixture()
      {:ok, _} = Tournaments.enable_manual_ranking(tournament)

      # The arbiter's own standings page warns about this. It was not
      # travelling, so the public page said "the arbiter chose this order"
      # while their screen said "...and it may no longer match".
      Repo.update_all(from(t in Tournament, where: t.id == ^tournament.id),
        set: [manual_ranking_stale: true]
      )

      standings = Snapshot.build(Tournaments.get_tournament!(tournament.id))["standings"]

      assert standings["manual_order"] == true
      assert standings["manual_stale"] == true
    end

    test "nothing is flagged when the arbiter has not taken the order over" do
      {tournament, _} = swiss_fixture()

      standings = Snapshot.build(tournament)["standings"]

      # False rather than null in all three, so a reader never handles three
      # states for one question.
      assert standings["manual_order"] == false
      assert standings["manual_stale"] == false
      assert standings["manual_incomplete"] == false
    end
  end

  describe "the tiebreak working" do
    test "every published part list totals the number in the row beside it" do
      # The whole premise. A public page showing contributions that do not
      # reach the total beside them reads as a bug in the arbiter's software,
      # in front of the players.
      {tournament, _} = swiss_fixture()
      %{"standings" => standings} = Snapshot.build(tournament)
      codes = Enum.map(standings["tiebreaks"], & &1["code"])

      for row <- standings["rows"], {code, working} <- row["working"] do
        at = Enum.find_index(codes, &(&1 == code))

        assert working["total"] == Enum.at(row["tiebreaks"], at),
               "#{code} for player #{row["player"]}: working totals " <>
                 "#{working["total"]}, the row says #{Enum.at(row["tiebreaks"], at)}"
      end
    end

    test "only the codes a reader could not work out for themselves are sent" do
      {tournament, _} = swiss_fixture()
      %{"standings" => standings} = Snapshot.build(tournament)

      sent = standings["rows"] |> Enum.flat_map(&Map.keys(&1["working"])) |> Enum.uniq()

      # Buchholz and its relatives depend on opponents' Article 16 adjusted
      # scores, which are not in the document and cannot be. The rest - wins,
      # games with Black, the running score - are visible in the results the
      # same document already carries.
      assert "BH" in sent
      refute "WIN" in sent
      refute "PS" in sent
      # Direct Encounter is not a per-round sum at all.
      refute "DE" in sent
    end

    test "an opponent is named by pairing number, never by database id" do
      {tournament, players} = swiss_fixture()
      %{"standings" => standings} = Snapshot.build(tournament)

      no_of_id = Map.new(players, fn {no, player} -> {player.id, no} end)

      # The fixture's precondition, asserted rather than assumed: if any
      # player's id equalled their pairing number, a leak of that id would be
      # invisible here. This is what the first version of this test got
      # wrong - it compared the published numbers against the set of ids,
      # which on a fresh database is the same set of small integers.
      assert Enum.all?(players, fn {no, player} -> player.id != no end)
      assert map_size(players) == 10

      # Who actually sat opposite whom, read from the pairings rather than
      # from the document under test.
      opponents =
        for round <- Repo.all(from r in Round, where: r.tournament_id == ^tournament.id),
            pairing <- Repo.all(from p in Pairing, where: p.round_id == ^round.id),
            {seat, other} <- [
              {pairing.white_player_id, pairing.black_player_id},
              {pairing.black_player_id, pairing.white_player_id}
            ],
            seat && other,
            into: %{},
            do: {{no_of_id[seat], round.number}, no_of_id[other]}

      named =
        for row <- standings["rows"],
            {_code, working} <- row["working"],
            part <- working["parts"],
            no = part["opponent"],
            is_integer(no),
            do: {row["player"], part["round"], no}

      assert named != []

      for {player, round, no} <- named do
        assert no == opponents[{player, round}],
               "round #{round}: the working for player #{player} names #{no}, " <>
                 "but they played #{inspect(opponents[{player, round}])}"
      end
    end

    test "a part omits its kind when it was simply counted" do
      {tournament, _} = swiss_fixture()
      %{"standings" => standings} = Snapshot.build(tournament)

      parts =
        for row <- standings["rows"],
            {_code, working} <- row["working"],
            part <- working["parts"],
            do: part

      # Absent means "played", the way absent means listed elsewhere in this
      # document. There are as many parts as players x codes x rounds, so the
      # commonest value is not worth a key.
      assert Enum.any?(parts, &(not Map.has_key?(&1, "kind")))
      assert Enum.all?(parts, &(Map.get(&1, "kind", "played") in ~w(played virtual cut excluded)))
    end

    test "hiding the tiebreak columns withholds the working entirely" do
      {tournament, _} = swiss_fixture()

      # Through the real writer: `public_display` is not in the changeset's
      # cast list, so `update_tournament/2` drops it silently and the test
      # would pass against a tournament that never hid anything.
      shown = Map.new(PairingsEngine.PublicDisplay.keys(), &{&1, "true"})

      {:ok, hidden} =
        Tournaments.set_public_display(tournament, %{shown | "tiebreaks" => "false"})

      %{"standings" => standings} = Snapshot.build(hidden)

      # Withheld at build time, not left for the renderer to hide. An
      # arbiter turning the columns off is hiding the arithmetic, and a
      # per-opponent decomposition is more of it than the columns showed.
      assert Enum.all?(standings["rows"], &(&1["working"] == %{}))
    end
  end

  describe "hiding individual tie-breaks" do
    test "a hidden code leaves the document entirely, values and all", %{} do
      {tournament, _} = swiss_fixture()
      {:ok, hidden} = Tournaments.set_public_display(tournament, all_shown(), %{"BH" => "true"})

      %{"standings" => standings} = Snapshot.build(hidden)

      # Declared columns, row values and working are all built from the same
      # list, so a hidden code leaves no gap and no null - it is simply not
      # part of the document.
      assert Enum.map(standings["tiebreaks"], & &1["code"]) == ["BH"]
      assert Enum.all?(standings["rows"], &(length(&1["tiebreaks"]) == 1))
      assert Enum.all?(standings["rows"], &(Map.keys(&1["working"]) == ["BH"]))
    end

    test "the page is told when the order used something it cannot show" do
      {tournament, _} = swiss_fixture()

      %{"standings" => all} = Snapshot.build(tournament)
      refute all["tiebreaks_withheld"]

      {:ok, hidden} = Tournaments.set_public_display(tournament, all_shown(), %{"BH" => "true"})
      %{"standings" => some} = Snapshot.build(hidden)

      # BHC1, SB and PS still decide placings and are no longer on the page.
      assert some["tiebreaks_withheld"]
    end

    test "hiding a tie-break that never affected the order withholds nothing" do
      # ARO is configured but C.07 Article 10 drops it - the fixture has an
      # unrated player - so it decided nothing and hiding it is not
      # withholding. The flag must not cry wolf.
      {tournament, _} = swiss_fixture()
      {:ok, tournament} = Tournaments.update_tournament(tournament, %{tiebreaks: ~w(BHC1 ARO)})

      ticked = %{"BHC1" => "true"}
      {:ok, hidden} = Tournaments.set_public_display(tournament, all_shown(), ticked)

      %{"standings" => standings} = Snapshot.build(hidden)

      assert Enum.map(standings["tiebreaks"], & &1["code"]) == ["BHC1"]
      refute standings["tiebreaks_withheld"]
    end

    test "turning the working off keeps the columns", %{} do
      {tournament, _} = swiss_fixture()

      {:ok, no_working} =
        Tournaments.set_public_display(
          tournament,
          Map.put(all_shown(), "tiebreak_working", "false"),
          nil
        )

      %{"standings" => standings} = Snapshot.build(no_working)

      assert standings["tiebreaks"] != []
      assert Enum.all?(standings["rows"], &(&1["tiebreaks"] != []))
      assert Enum.all?(standings["rows"], &(&1["working"] == %{}))
    end

    test "not passing a tie-break list leaves the hidden set alone" do
      {tournament, _} = swiss_fixture()
      {:ok, hidden} = Tournaments.set_public_display(tournament, all_shown(), %{"BH" => "true"})
      assert hidden.public_hidden_tiebreaks != []

      # A caller editing only the ordinary toggles must not silently unhide
      # everything - `nil` means "not editing that", `%{}` means "none ticked".
      {:ok, still} = Tournaments.set_public_display(hidden, all_shown(), nil)
      assert still.public_hidden_tiebreaks == hidden.public_hidden_tiebreaks

      {:ok, none} = Tournaments.set_public_display(hidden, all_shown(), %{})
      assert Enum.sort(none.public_hidden_tiebreaks) == Enum.sort(still.tiebreaks)
    end

    test "a code the tournament no longer uses is forgotten, not remembered" do
      {tournament, _} = swiss_fixture()
      {:ok, hidden} = Tournaments.set_public_display(tournament, all_shown(), %{"BH" => "true"})
      assert "SB" in hidden.public_hidden_tiebreaks

      {:ok, fewer} = Tournaments.update_tournament(hidden, %{tiebreaks: ~w(BH BHC1)})
      {:ok, resaved} = Tournaments.set_public_display(fewer, all_shown(), %{"BH" => "true"})

      # SB is not in the tournament any more, so it is not in the hidden set.
      # Putting it back later starts it shown, like everything else here.
      assert resaved.public_hidden_tiebreaks == ["BHC1"]
    end
  end

  # Every display key ticked, which is what the settings form sends when
  # nothing is switched off.
  defp all_shown, do: Map.new(PairingsEngine.PublicDisplay.keys(), &{&1, "true"})

  # A board the arbiter emptied one seat of, and then recorded a result on -
  # the shape a SWAR or TRF import carries, and the one an arbiter reaches by
  # forfeiting a board whose opponent has already gone.
  #
  # The fixture's round is deliberately two boards that look identical from
  # the outside: both have one empty seat, and only the result differs. The
  # SWAR publish path grew the same fix first
  # (`Bel.SwarPublish.single_seat_award/2`) and now has its own copy of these
  # two tests.
  describe "a vacated seat that carries a result" do
    test "is published as what was recorded, not as a full-point bye" do
      {tournament, forfeited, _byed} = vacancy_fixture("0-1FF")

      round = Enum.find(Snapshot.build(tournament)["rounds"], &(&1["number"] == 1))

      # The bug, in one row: this used to read
      #   %{"kind" => "pairing-allocated", "points" => 1.0}
      # for a player who FORFEITED the round. `bye_value` was published for
      # every one-seated board, whatever was actually on it.
      assert %{
               "player" => forfeited.pairing_number,
               "kind" => "vacated-seat",
               "result" => "0-1FF",
               "points" => 0.0
             } in round["byes"]
    end

    test "leaves a genuine pairing-allocated bye exactly as it was" do
      {tournament, _forfeited, byed} = vacancy_fixture("0-1FF")

      round = Enum.find(Snapshot.build(tournament)["rounds"], &(&1["number"] == 1))

      # The control. This board also has one empty seat; what makes it a bye
      # is that nothing was recorded on it. Had the fix been "stop calling
      # one-seated boards byes", this row would have moved too - and it must
      # not, because it is the ordinary odd-player-count bye worth `bye_value`.
      assert %{
               "player" => byed.pairing_number,
               "kind" => "pairing-allocated",
               "points" => 1.0
             } in round["byes"]
    end

    test "pays what the crosstable in the same document pays" do
      # The property that matters, and the one a wrong constant cannot
      # satisfy by luck: OpenResults rebuilds a player's running total by
      # adding these per-round figures up, while the same payload carries
      # standings computed by `Standings`. Two answers to one question show
      # up on the public page as a total that does not add up, with nothing
      # on it able to explain why.
      #
      # Every result that can sit on a vacated seat, so the agreement is a
      # rule rather than one lucky code.
      for {result, expected} <- [{"1-0FF", 1.0}, {"0-1FF", 0.0}, {"0-0FF", 0.0}, {"1/2-1/2", 0.5}] do
        {tournament, seated, _byed} = vacancy_fixture(result)

        snapshot = Snapshot.build(tournament)
        round = Enum.find(snapshot["rounds"], &(&1["number"] == 1))
        published = Enum.find(round["byes"], &(&1["player"] == seated.pairing_number))

        ranked =
          Enum.find(snapshot["standings"]["rows"], &(&1["player"] == seated.pairing_number))

        assert published["points"] == expected,
               "#{result}: published #{inspect(published["points"])}, expected #{expected}"

        assert ranked["points"] == expected,
               "#{result}: the standings in the same document say #{inspect(ranked["points"])}"
      end
    end
  end

  describe "build/1 - the \"Results round N\" switch" do
    # Result tokens used on no board outside round 2, so their absence from
    # the JSON is a direct check that no round-2 result travelled.
    @withheld_tokens ["1/2-0", "0-1U", "0-1FF"]

    # Round 1: published, complete, standings after it published. Round 2:
    # published, every result entered (so it is COMPLETE, the case a cap on
    # "complete rounds" alone would let through), results switch off. It
    # also carries a result recorded against a vacated seat and a requested
    # half-point bye.
    defp withheld_fixture do
      tournament =
        Repo.insert!(%Tournament{
          name: "Withheld",
          type: "swiss",
          pairing_system: "swiss",
          rounds_count: 3,
          tiebreaks: ~w(BH SB),
          publish_mode: "manual",
          public_slug: "withheld-#{System.unique_integer([:positive])}"
        })

      players =
        for no <- 1..7, into: %{} do
          {no,
           Repo.insert!(%Player{
             tournament_id: tournament.id,
             pairing_number: no,
             name: "Player #{no}",
             fide_rating: 2100 - no
           })}
        end

      published = ~U[2026-03-01 14:00:00Z]
      r1 = insert_round(tournament, 1, published, true)
      r2 = insert_round(tournament, 2, published, false)

      boards(r1, [
        {1, players[1], players[2], "1-0"},
        {2, players[3], players[4], "1/2-1/2"},
        {3, players[5], players[6], "0-1"}
      ])

      boards(r2, [
        {1, players[2], players[3], "1/2-0"},
        {2, players[4], players[1], "0-1U"}
      ])

      # A forfeit recorded against a vacated seat: a result, typed mid-round.
      Repo.insert!(%Pairing{
        round_id: r2.id,
        board: 3,
        white_player_id: players[6].id,
        black_player_id: nil,
        result: "0-1FF"
      })

      Repo.insert_all("byes", [
        %{
          tournament_id: tournament.id,
          player_id: players[5].id,
          round: 2,
          type: "requested-half"
        },
        %{tournament_id: tournament.id, player_id: players[7].id, round: 1, type: "absent"}
      ])

      {:ok, tournament} = Tournaments.publish_standings_through(tournament, 1)

      {tournament, players}
    end

    test "no result, and nothing derived from a result, travels for a withheld round" do
      {tournament, players} = withheld_fixture()

      snapshot = Snapshot.build(tournament)
      json = Jason.encode!(snapshot)

      round1 = Enum.find(snapshot["rounds"], &(&1["number"] == 1))
      round2 = Enum.find(snapshot["rounds"], &(&1["number"] == 2))

      # The pairings still travel - the switch withholds results, not boards.
      assert round1["results_public"] == true
      assert round2["results_public"] == false
      assert Enum.map(round2["boards"], & &1["board"]) == [1, 2]
      assert Enum.all?(round2["boards"], &is_nil(&1["result"]))

      # The vacated-seat row is a result, so it is withheld whole; the
      # requested bye is on the pairing sheet and stays.
      refute Enum.any?(round2["byes"], &(&1["kind"] == "vacated-seat"))
      refute json =~ "vacated-seat"

      assert round2["byes"] == [
               %{"player" => players[5].pairing_number, "kind" => "half-point", "points" => 0.5}
             ]

      for token <- @withheld_tokens, do: refute(json =~ token)

      # Standings stop at round 1 - complete rounds alone would have allowed 2.
      assert snapshot["standings"]["after_round"] == 1

      # And every row, and every piece of tie-break working, is round 1 only.
      points = Map.new(snapshot["standings"]["rows"], &{&1["player"], &1["points"]})
      assert points[1] == 1.0
      assert points[2] == 0.0
      assert points[3] == 0.5

      for row <- snapshot["standings"]["rows"],
          {_code, %{"parts" => parts}} <- row["working"],
          part <- parts do
        assert part["round"] <= 1
      end
    end

    test "switching the results on sends them as entered" do
      {tournament, _players} = withheld_fixture()

      {:ok, tournament} = Tournaments.publish_results(tournament, 2)
      snapshot = Snapshot.build(tournament)
      json = Jason.encode!(snapshot)

      round2 = Enum.find(snapshot["rounds"], &(&1["number"] == 2))

      assert round2["results_public"] == true
      assert result_at(snapshot, 2, 1) == "1/2-0"
      assert result_at(snapshot, 2, 2) == "0-1U"
      assert json =~ "vacated-seat"
      # Standings are a separate switch and stay where they were.
      assert snapshot["standings"]["after_round"] == 1
    end

    test "public standings after the round force its results public, whatever the switch says" do
      {tournament, _players} = withheld_fixture()

      {:ok, tournament} = Tournaments.publish_standings_through(tournament, 2)
      snapshot = Snapshot.build(tournament)

      assert snapshot["standings"]["after_round"] == 2
      assert Enum.find(snapshot["rounds"], &(&1["number"] == 2))["results_public"] == true
      assert result_at(snapshot, 2, 1) == "1/2-0"
    end

    test "immediate mode sends every round's results" do
      {tournament, _players} = withheld_fixture()

      tournament =
        tournament |> Ecto.Changeset.change(publish_mode: "immediate") |> Repo.update!()

      snapshot = Snapshot.build(tournament)

      assert Enum.all?(snapshot["rounds"], & &1["results_public"])
      assert result_at(snapshot, 2, 2) == "0-1U"
    end
  end

  describe "team tournaments" do
    test "a team Swiss paired by teams carries the team fields" do
      {t, _teams} = team_snapshot_fixture()

      snapshot =
        Snapshot.build(%{
          t
          | type: "team-swiss",
            pairing_system: "swiss",
            team_pairing_mode: "teams"
        })

      assert snapshot["tournament"]["team_event"] == true
      assert is_list(snapshot["teams"]) and snapshot["teams"] != []
      assert Map.has_key?(snapshot, "team_standings")
    end

    test "a team Swiss already paired player by player publishes as an individual event" do
      # Flagged as a team event it would show empty team standings on the
      # results site in place of its real individual ones.
      {t, _teams} = team_snapshot_fixture()

      snapshot =
        Snapshot.build(%{
          t
          | type: "team-swiss",
            pairing_system: "swiss",
            team_pairing_mode: "players"
        })

      refute Map.has_key?(snapshot["tournament"], "team_event")
      refute Map.has_key?(snapshot, "teams")
      refute Map.has_key?(snapshot, "team_standings")
      refute Map.has_key?(snapshot, "board_stats")
      assert Enum.all?(snapshot["rounds"], &(not Map.has_key?(&1, "matches")))
    end

    test "team_event, teams, matches and team_standings travel; individual snapshot fields are untouched" do
      {t, _teams} = team_snapshot_fixture()

      snapshot = Snapshot.build(t)

      assert snapshot["tournament"]["team_event"] == true

      teams = snapshot["teams"]
      assert length(teams) == 4
      antwerp = Enum.find(teams, &(&1["name"] == "Antwerp Knights"))
      assert antwerp["short_name"] == nil
      assert antwerp["captain"] == "Jan Peeters"
      assert is_integer(antwerp["no"])
      # The whole squad: the 2 who sat at a board keep their issued numbers and
      # the reserve who never played is numbered provisionally, like any player
      # on the roster who has not been paired yet.
      assert length(antwerp["players"]) == 3

      round1 = Enum.find(snapshot["rounds"], &(&1["number"] == 1))
      assert is_list(round1["matches"]) and round1["matches"] != []

      match = hd(round1["matches"])
      assert Map.has_key?(match, "team_a")
      assert Map.has_key?(match, "team_b")
      assert Map.has_key?(match, "board1_white_team")
      assert is_list(match["boards"])
      assert Map.has_key?(match, "game_points")
      assert Map.has_key?(match, "match_points")

      ts = snapshot["team_standings"]
      # Same setting-driven gate as individual standings: nobody has
      # published a standings cut-off yet, so it reads 0 even though round 1
      # is complete.
      assert ts["after_round"] == 0
      row = hd(ts["rows"])
      assert Map.keys(row) |> Enum.sort() == ~w(gp mp rank team tiebreaks working)
      assert snapshot["board_stats"] == []

      # Once the arbiter publishes standings through round 1, both team
      # standings and board statistics start counting it - the same setting,
      # the same cut-off, for the same reason.
      {:ok, t} = Tournaments.publish_standings_through(t, 1)
      snapshot = Snapshot.build(Tournaments.get_tournament!(t.id))

      assert snapshot["team_standings"]["after_round"] == 1
      board_stats = snapshot["board_stats"]
      assert board_stats != []
      stat = hd(board_stats)

      assert Map.keys(stat) |> Enum.sort() ==
               ~w(board games percentage performance player points team)
    end

    test "an individual tournament's snapshot carries none of the team keys" do
      {tournament, _} = swiss_fixture()
      snapshot = Snapshot.build(tournament)

      refute Map.has_key?(snapshot["tournament"], "team_event")
      refute Map.has_key?(snapshot, "teams")
      refute Map.has_key?(snapshot, "team_standings")
      refute Map.has_key?(snapshot, "board_stats")
      refute Enum.any?(snapshot["rounds"], &Map.has_key?(&1, "matches"))
    end

    test "a match's points are withheld exactly like a board's result" do
      {t, _teams} = team_snapshot_fixture()

      # Round 1 is published but its results switch has never been turned on.
      snapshot = Snapshot.build(t)
      round1 = Enum.find(snapshot["rounds"], &(&1["number"] == 1))
      assert round1["results_public"] == false

      for match <- round1["matches"] do
        assert match["game_points"] == nil
        assert match["match_points"] == nil
        # The teams themselves are on the pairing sheet, not a result - they
        # still travel, same as `boards/3` keeps both players.
        refute is_nil(match["team_a"])
      end

      {:ok, t} = Tournaments.publish_results(t, 1)
      snapshot = Snapshot.build(Tournaments.get_tournament!(t.id))
      round1 = Enum.find(snapshot["rounds"], &(&1["number"] == 1))
      assert round1["results_public"] == true

      match = hd(round1["matches"])
      refute is_nil(match["game_points"])
      refute is_nil(match["match_points"])
    end

    test "a match forfeited by decision says whom to, null otherwise, and is withheld with the match points" do
      {t, teams} = team_snapshot_fixture()
      antwerp = Enum.find(teams, &(&1.name == "Antwerp Knights"))
      round1 = Tournaments.get_round(t.id, 1)

      match =
        round1.id
        |> Tournaments.list_matches()
        |> Enum.find(&(antwerp.id in [&1.team_a_id, &1.team_b_id]))

      {:ok, _} = PairingsEngine.TeamMatches.forfeit_match(t, match, antwerp.id)

      matches_of = fn t ->
        Snapshot.build(Tournaments.get_tournament!(t.id))["rounds"]
        |> Enum.find(&(&1["number"] == 1))
        |> Map.fetch!("matches")
      end

      # Withheld: round 1's results switch is off, so the decision - which
      # says who won - is null exactly as the match points are.
      for m <- matches_of.(t) do
        assert Map.has_key?(m, "forfeit_decision")
        assert m["forfeit_decision"] == nil
        assert m["match_points"] == nil
      end

      {:ok, t} = Tournaments.publish_results(t, 1)
      antwerp_no = Tournaments.get_team(t.id, antwerp.id).pairing_number

      [forfeited, other] =
        Enum.sort_by(matches_of.(t), &(antwerp_no not in [&1["team_a"], &1["team_b"]]))

      # Present: the team the arbiter awarded it to, by team number.
      assert forfeited["forfeit_decision"] == %{"to" => antwerp_no}
      refute is_nil(forfeited["match_points"])

      # Null: a match decided on its boards.
      assert Map.has_key?(other, "forfeit_decision")
      assert other["forfeit_decision"] == nil
      refute is_nil(other["match_points"])

      # Withheld while the match is incomplete, as its match points are: a
      # board of the forfeited match loses its result.
      board = Enum.find(Tournaments.get_round(t.id, 1).pairings, &(&1.match_id == match.id))
      {:ok, _} = Tournaments.update_pairing_result(board, "")

      [forfeited, _other] =
        Enum.sort_by(matches_of.(t), &(antwerp_no not in [&1["team_a"], &1["team_b"]]))

      assert {forfeited["match_points"], forfeited["forfeit_decision"]} == {nil, nil}
      {:ok, _} = Tournaments.update_pairing_result(Repo.reload!(board), board.result)

      # Withdrawn, it is null again.
      {:ok, _} = PairingsEngine.TeamMatches.withdraw_forfeit(t, Repo.reload!(match))
      assert Enum.all?(matches_of.(t), &is_nil(&1["forfeit_decision"]))
    end

    test "an individual tournament never carries forfeit_decision (absent: no matches at all)" do
      {tournament, _} = swiss_fixture()
      rounds = Snapshot.build(tournament)["rounds"]
      refute Enum.any?(rounds, &Map.has_key?(&1, "matches"))
    end

    test "an unpaired round leaves no trace of its matches" do
      {t, _teams} = team_snapshot_fixture()

      # Round 2 exists (paired) but was never published - not even the shell
      # of a round with no matches, exactly like an unpublished individual
      # round leaves no numbered entry in `rounds` at all.
      refute Enum.any?(Snapshot.build(t)["rounds"], &(&1["number"] == 2))
    end
  end

  describe "the cross-repo contract fixtures" do
    # A drift check, not a writer: it builds each fixture in memory with the
    # same builders `mix pairings.snapshot_fixtures` uses
    # (`PairingsEngine.SnapshotFixtures`) and compares the result against
    # what is already committed in `../openresults/test/fixtures`. Nothing
    # on disk changes here - see docs/test-quality-2026-09-13.md, which
    # flagged the previous version of this test (writing fixtures as a side
    # effect, asserting nothing) as the thing to fix.
    #
    # Excluded, not failed, when the sibling checkout is not present (CI,
    # most worktrees) - see test/test_helper.exs, which uses
    # `SnapshotFixtures.fixture_dir/0` the same way to decide whether this
    # tag can even run, and prints why when it can't.
    @describetag :snapshot_fixtures

    for {name, fun} <- SnapshotFixtures.contract_fixtures() do
      @fixture_name name
      @fixture_fun fun

      test "#{name} matches the committed fixture" do
        committed_path = Path.join(SnapshotFixtures.fixture_dir(), @fixture_name)

        unless File.exists?(committed_path) do
          flunk(
            "#{@fixture_name} is not committed in openresults yet - run " <>
              "`MIX_ENV=test mix pairings.snapshot_fixtures` and commit it there"
          )
        end

        current = apply(SnapshotFixtures, @fixture_fun, []) |> SnapshotFixtures.stable_json()
        committed = File.read!(committed_path)

        assert current == committed, """
        the OpenResults contract fixtures are stale - run
        `MIX_ENV=test mix pairings.snapshot_fixtures` and commit them in openresults
        (#{@fixture_name} differs)
        """
      end
    end
  end

  ## ---------- fixtures ----------

  # One published round, four players, two boards with an empty black seat.
  #
  # Board 1 carries `result` and is the case under test; board 2 carries the
  # blank an untouched pairing-allocated bye has, and is the control. Nothing
  # else happens in the tournament, so each seated player's whole score is
  # what their own board paid - which is what lets the third test compare the
  # published bye row against the standings without arithmetic in the test.
  defp vacancy_fixture(result) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Vacancy",
        type: "swiss",
        pairing_system: "swiss",
        rounds_count: 1,
        publish_mode: "manual",
        public_slug: "vacancy-#{System.unique_integer([:positive])}"
      })

    [seated, byed] =
      for no <- 1..2 do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          pairing_number: no,
          name: "Player #{no}",
          fide_rating: 2000 - no
        })
      end

    round = insert_round(tournament, 1, ~U[2026-03-01 14:00:00Z])

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: seated.id,
      black_player_id: nil,
      result: result
    })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: byed.id,
      black_player_id: nil,
      result: "bye"
    })

    # Round 1's pairings being public only floors public standings at round 0
    # (rule 1 - see `Tournaments.effective_standings_through/1`); this
    # fixture is a single-round tournament, so round 1's OWN standings need
    # an explicit publish to exercise the property under test - that the
    # published per-board points agree with the standings in the same
    # document.
    {:ok, tournament} = Tournaments.publish_standings_through(tournament, 1)

    {tournament, seated, byed}
  end

  defp result_at(snapshot, round_number, board_number) do
    snapshot["rounds"]
    |> Enum.find(&(&1["number"] == round_number))
    |> Map.fetch!("boards")
    |> Enum.find(&(&1["board"] == board_number))
    |> Map.fetch!("result")
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
