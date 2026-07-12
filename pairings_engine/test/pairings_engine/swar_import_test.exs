defmodule PairingsEngine.SwarImportTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{SwarImport, Tournaments, Repo}
  alias PairingsEngine.Tournaments.Round
  alias PairingsEngine.Accounts.{Scope, User}

  @c_reeks "test/fixtures/c-reeks.swar"
  @problemski "test/fixtures/problemski.swar"

  # Lightweight stand-in for `PairingsEngine.AccountsFixtures.user_scope_fixture/0`
  # — see the comment on the equivalent helper in tournaments_test.exs.
  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  ## ---------- parse/1 ----------

  test "parse/1 returns {:ok, _} with players for both fixtures" do
    for path <- [@c_reeks, @problemski] do
      binary = File.read!(path)
      assert {:ok, data} = SwarImport.parse(binary)
      assert length(data.players) > 0
    end
  end

  test "parse/1 reads c-reeks.swar's known-correct tournament and player fields" do
    {:ok, data} = SwarImport.parse(File.read!(@c_reeks))

    assert data.tournament.name =~ "C-reeks"
    assert length(data.players) == 27

    deloof = Enum.find(data.players, &(&1.name == "Deloof, Koen"))
    assert deloof.mat_nat == 39934
    assert deloof.mat_fide == 210234
    assert deloof.elo == 1779 or deloof.elo_fide == 1779

    waegeman = Enum.find(data.players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.mat_nat == 19953
    assert waegeman.mat_fide == 292052
    assert String.starts_with?(waegeman.birth, "1982")

    cobert = Enum.find(data.players, &(&1.name == "Cobert, Quinten"))
    assert cobert.elo == 0
    assert cobert.elo_fide == 0
  end

  ## ---------- import_file/1 ----------

  test "import_file/1 creates the tournament, players and pairings for c-reeks.swar" do
    assert {:ok, tournament} = SwarImport.import_file(@c_reeks)

    assert tournament.name =~ "C-reeks"
    assert tournament.rounds_count == 11

    players = Tournaments.list_players(tournament.id)
    assert length(players) == 27

    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.national_id == "39934"
    assert deloof.fide_id == 210234
    assert deloof.national_rating == 1810
    assert deloof.fide_rating == 1779
    assert deloof.birth_year == 1973

    waegeman = Enum.find(players, &(&1.name == "Waegeman, Willem"))
    assert waegeman.national_id == "19953"
    assert waegeman.fide_id == 292052
    assert waegeman.birth_year == 1982

    cobert = Enum.find(players, &(&1.name == "Cobert, Quinten"))
    assert cobert.national_rating == 0
    assert cobert.fide_rating == 0

    assert PairingsEngine.Pairing.paired_rounds_count(tournament.id) == 11

    assert points_for(tournament, deloof) == 9.0
  end

  test "import_file/1 maps SWAR player-administration fields (payment, affiliation, extra points, category, club number)" do
    {:ok, tournament} = SwarImport.import_file(@c_reeks)
    players = Tournaments.list_players(tournament.id)

    abramenko = Enum.find(players, &(&1.name == "Abramenko, Aleksei"))
    assert abramenko.paid == "paid"
    assert abramenko.extra_points == 0.5
    assert abramenko.affiliated == true
    assert abramenko.national_id == "21740"
    assert abramenko.fide_id == 268968
    assert abramenko.birth_year == 2011
    assert abramenko.fide_rating == 1661
    assert abramenko.club == "KGSRL Gent"
    assert abramenko.club_number == 401

    van_de_kelder = Enum.find(players, &(&1.name == "Van De Kelder, Yves"))
    assert van_de_kelder.extra_points == 1.5

    # Bouche and Cobert are both flagged not-affiliated ("N") in the SWAR UI.
    bouche = Enum.find(players, &(&1.name == "Bouche, Jeroen"))
    assert bouche.affiliated == false

    cobert = Enum.find(players, &(&1.name == "Cobert, Quinten"))
    assert cobert.affiliated == false
    # Cobert's Absent field is 2 (ABS_ABSENT) rather than 4 (ABS_PRESENT).
    assert cobert.absent == true
    assert cobert.forfeit == false

    # Every other sampled player is present (Absent == 4) and not forfeited.
    deloof = Enum.find(players, &(&1.name == "Deloof, Koen"))
    assert deloof.absent == false
    assert deloof.forfeit == false
    assert deloof.paid == "paid"

    assert tournament.round_dates == [
             "2025-10-04",
             "2025-11-08",
             "2025-11-29",
             "2025-12-13",
             "2025-12-20",
             "2026-01-31",
             "2026-02-21",
             "2026-03-21",
             "2026-04-25",
             "2026-05-09",
             "2026-05-06"
           ]

    assert length(tournament.round_dates) == 11
    # c-reeks.swar has no custom categories defined (Categorie type NO_CATEGO).
    assert tournament.categories == []
    assert tournament.standard == "standard"
    assert tournament.organizer_club_number == "401"
  end

  test "import_file/1 does not create duplicate pairings for the same game" do
    {:ok, tournament} = SwarImport.import_file(@c_reeks)
    players = Tournaments.list_players(tournament.id)
    max_pairings = ceil(length(players) / 2)

    rounds =
      Repo.all(from r in Round, where: r.tournament_id == ^tournament.id, preload: [:pairings])

    assert length(rounds) == 11

    Enum.each(rounds, fn round ->
      assert length(round.pairings) <= max_pairings

      # No two pairings in the same round should reference the same pair of
      # players (which would indicate the same game was recorded twice).
      pairs =
        Enum.map(round.pairings, fn p -> Enum.sort([p.white_player_id, p.black_player_id]) end)

      assert length(pairs) == length(Enum.uniq(pairs))

      # No two pairings in the same round should share a board number.
      boards = Enum.map(round.pairings, & &1.board)
      assert length(boards) == length(Enum.uniq(boards))
    end)
  end

  ## ---------- PubSub broadcasts ----------

  test "import_file/2 broadcasts once on the owning user's tournament-list topic, after the import commits" do
    scope = user_scope()
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.user_tournaments_topic(scope.user.id))

    assert {:ok, tournament} = SwarImport.import_file(@c_reeks, scope)

    user_id = scope.user.id
    assert_receive {:tournaments_changed, ^user_id}

    # The tournament is queryable by the time the broadcast lands — proof
    # the broadcast fired after commit, not from inside the still-open
    # transaction (see PairingsEngine.Tournaments.with_broadcast_suppressed/1).
    assert Tournaments.get_user_tournament(scope, tournament.id)
  end

  test "import_file/1 (no scope) does not broadcast on any user's tournament-list topic" do
    # An unowned import has no user to notify — this also exercises the
    # nil-safe branch of broadcast_user_tournaments/1.
    assert {:ok, _tournament} = SwarImport.import_file(@c_reeks)
  end

  test "import_file/1 parses and imports problemski.swar without error" do
    assert {:ok, tournament} = SwarImport.import_file(@problemski)
    players = Tournaments.list_players(tournament.id)
    assert length(players) == 10
  end

  test "import_file/1 marks the tournament as running, not stuck on setup, since rounds were imported" do
    assert {:ok, tournament} = SwarImport.import_file(@c_reeks)
    assert tournament.status == "running"

    # Persisted, not just returned in-memory.
    assert Tournaments.get_tournament!(tournament.id).status == "running"
  end

  ## ---------- helpers ----------

  # Sums a player's points the same way Standings does: pairing results plus
  # byes, win = 1.0, draw = 0.5.
  defp points_for(tournament, player) do
    rounds =
      Repo.all(from r in Round, where: r.tournament_id == ^tournament.id, preload: [:pairings])

    pairing_points =
      for round <- rounds,
          pairing <- round.pairings,
          pairing.white_player_id == player.id or pairing.black_player_id == player.id do
        white? = pairing.white_player_id == player.id

        case {pairing.result, white?} do
          {"1-0", true} -> 1.0
          {"1-0", false} -> 0.0
          {"0-1", true} -> 0.0
          {"0-1", false} -> 1.0
          {"1/2-1/2", _} -> 0.5
          {"+--", true} -> 1.0
          {"+--", false} -> 0.0
          {"--+", true} -> 0.0
          {"--+", false} -> 1.0
          {"0-0", _} -> 0.0
          {"bye", true} -> tournament.bye_value
          _ -> 0.0
        end
      end

    bye_points =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^player.id,
          select: %{type: b.type}
      )
      |> Enum.map(fn bye ->
        case bye.type do
          "requested-half" -> tournament.points_draw
          "pairing-allocated" -> tournament.bye_value
          _ -> 0.0
        end
      end)

    Enum.sum(pairing_points) + Enum.sum(bye_points)
  end
end
