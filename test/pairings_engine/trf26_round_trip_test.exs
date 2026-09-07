defmodule PairingsEngine.Trf26RoundTripTest do
  @moduledoc """
  What a TRF26 file says ABOUT the tournament, out and back again.

  Every setting here was parsed and then dropped until 0.48.0, which is the
  quiet kind of wrong: the re-imported tournament looked complete and was
  configured differently from the one that left - scored on other values,
  pairing pairs its arbiter had separated, on a different edition of the
  rules.
  """

  # async: false for the same reason the other import/export tests are:
  # a write-heavy fixture plus a full transactional import contend on
  # SQLite's single writer lock.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, TrfExport, TrfImport, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  # Six players, one round played, and every tournament-level setting a
  # TRF26 file can carry set to something other than its default.
  defp configured(attrs \\ %{}) do
    tournament =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Round Trip",
            type: "swiss",
            pairing_system: "swiss",
            pairing_engine: "ainalrami",
            rounds_count: 9,
            round_dates: for(n <- 1..9, do: "2026-03-0#{rem(n, 9) + 1}"),
            tiebreaks: ~w(BH SB),
            points_win: 3.0,
            points_draw: 1.0,
            points_loss: 0.0,
            bye_value: 2.0,
            rate_of_play: "90min/end+30sec/move from move 1"
          },
          attrs
        )
      )

    players =
      for {name, rating} <- [
            {"Alice", 2200},
            {"Bob", 2100},
            {"Carol", 2000},
            {"Dave", 1900},
            {"Eve", 1800},
            {"Frank", 1700}
          ] do
        {:ok, player} =
          Tournaments.create_player(tournament.id, %{"name" => name, "fide_rating" => rating})

        player
      end

    PairingsEngine.Pairing.ensure_pairing_numbers(tournament, players)
    players = Tournaments.list_players(tournament.id) |> Enum.sort_by(& &1.pairing_number)

    [a, b, c, d, e, f] = players
    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    board(round, 1, a, d, "1-0")
    board(round, 2, b, e, "1/2-1/2")
    board(round, 3, c, f, "0-1")

    {Repo.reload!(tournament), Map.new(players, &{&1.name, &1})}
  end

  defp board(round, board, white, black, result) do
    Repo.insert!(%Pairing{
      round_id: round.id,
      board: board,
      white_player_id: white.id,
      black_player_id: black.id,
      result: result
    })
  end

  defp round_trip(tournament) do
    assert {:ok, text} = TrfExport.export(tournament)
    assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope())
    {imported, warnings, text}
  end

  defp imported_players(tournament), do: Tournaments.list_players(tournament.id)

  test "the scoring system survives, so the re-imported tournament pairs the same brackets" do
    {tournament, _} = configured()
    {imported, warnings, text} = round_trip(tournament)

    assert text =~ "\r\n162  W 3.0    D 1.0    L 0.0    A 0.0    P 2.0\r\n"

    assert imported.points_win == 3.0
    assert imported.points_draw == 1.0
    assert imported.points_loss == 0.0
    assert imported.bye_value == 2.0

    # The totals in the file were computed at 3-1-0; imported at 1/half/0
    # they would every one of them disagree, which is what this asserts.
    assert warnings == []
  end

  test "the standard system says nothing, and imports as the standard system" do
    {tournament, _} =
      configured(%{points_win: 1.0, points_draw: 0.5, points_loss: 0.0, bye_value: 1.0})

    {imported, _warnings, text} = round_trip(tournament)

    refute text =~ "162"
    assert imported.points_win == 1.0
    assert imported.bye_value == 1.0
  end

  test "which edition of the rules paired the boards survives" do
    {ainalrami, _} = configured()
    {imported, _, _} = round_trip(ainalrami)
    assert imported.pairing_engine == "ainalrami"
    assert imported.pairing_system == "swiss"

    {javafo, _} = configured(%{pairing_engine: "javafo"})
    {imported, _, text} = round_trip(javafo)
    assert text =~ "\r\n192 FIDE_DUTCH_2017\r\n"
    assert imported.pairing_engine == "javafo"
  end

  test "the tie-breaks survive, and one this app cannot compute is dropped" do
    {tournament, _} = configured()
    {imported, _, _} = round_trip(tournament)
    assert imported.tiebreaks == ~w(BH SB)

    # A code from FIDE's list that this installation has no calculator for
    # must not be listed as configured - it would be a standings column
    # that silently never fills.
    {:ok, text} = TrfExport.export(tournament)
    text = String.replace(text, "202 BH,SB", "202 BH,ZZZ,SB")
    assert {:ok, imported, _} = TrfImport.import_text(text, user_scope())
    assert imported.tiebreaks == ~w(BH SB)
  end

  test "the tournament's length survives, not just how much of it has been played" do
    {tournament, _} = configured()
    {imported, _, _} = round_trip(tournament)

    # One round played of nine. Before 0.48.0 this came back a one-round
    # tournament, and the engine's final-round colour rule then applied to
    # round two.
    assert imported.rounds_count == 9
    assert PairingsEngine.Pairing.paired_rounds_count(imported.id) == 1
  end

  test "prohibited pairings survive, so the re-imported tournament still separates them" do
    {tournament, players} = configured()
    alice = players["Alice"]
    frank = players["Frank"]
    {:ok, _} = Tournaments.add_forbidden_pairing(tournament, alice.id, frank.id)

    {imported, warnings, text} = round_trip(tournament)
    assert text =~ "\r\n260   1   9    1    6\r\n"
    assert warnings == []

    assert [pair] = Tournaments.list_forbidden_pairings(imported.id)
    assert Enum.sort([pair.player_a.name, pair.player_b.name]) == ["Alice", "Frank"]
  end

  test "a club exclusion arrives as the pairs it stands for" do
    {tournament, players} = configured(%{club_exclusion: "all"})

    for name <- ~w(Alice Bob) do
      {:ok, _} = Tournaments.update_player(players[name], %{"club" => "Chess Club"})
    end

    {imported, _, text} = round_trip(Repo.reload!(tournament))
    assert text =~ "\r\n260   1   9    1    2\r\n"

    # The RULE is not in the file - TRF has no way to say "same club" - so
    # it arrives as the pair it produced. That keeps the two apart, which
    # is what the arbiter asked for.
    assert imported.club_exclusion == "none"
    assert [pair] = Tournaments.list_forbidden_pairings(imported.id)
    assert Enum.sort([pair.player_a.name, pair.player_b.name]) == ["Alice", "Bob"]
  end

  test "a rule the file limits to some rounds is widened, and says so" do
    {tournament, _} = configured()
    {:ok, text} = TrfExport.export(tournament)
    text = text <> "260 001 002    1    3\r\n"

    assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope())
    assert [pair] = Tournaments.list_forbidden_pairings(imported.id)
    assert Enum.sort([pair.player_a.name, pair.player_b.name]) == ["Alice", "Carol"]

    assert Enum.any?(warnings, &(&1[:kind] == :note and &1.text =~ "applied only to some rounds"))
  end

  test "a bye granted for the round nobody has paired yet survives" do
    {tournament, players} = configured()

    Repo.insert_all("byes", [
      %{
        tournament_id: tournament.id,
        player_id: players["Eve"].id,
        round: 2,
        type: "requested-half"
      },
      %{
        tournament_id: tournament.id,
        player_id: players["Frank"].id,
        round: 2,
        type: "requested-zero"
      }
    ])

    {imported, warnings, text} = round_trip(tournament)
    assert text =~ "\r\n240 H 002    5\r\n"
    assert text =~ "\r\n240 Z 002    6\r\n"
    assert warnings == []

    # Round two is not a Round: nobody has paired it. The byes are the
    # arbiter's instruction for when somebody does.
    assert PairingsEngine.Pairing.paired_rounds_count(imported.id) == 1

    byes =
      imported.id
      |> Tournaments.list_byes_for_round(2)
      |> Map.new(&{&1.player.name, &1.type})

    assert byes == %{"Eve" => "requested-half", "Frank" => "requested-zero"}
  end

  test "the older spelling carries the same bye as a column an engine reads" do
    {tournament, players} = configured()

    Repo.insert_all("byes", [
      %{
        tournament_id: tournament.id,
        player_id: players["Eve"].id,
        round: 2,
        type: "requested-half"
      }
    ])

    assert {:ok, text} = TrfExport.export(tournament, nil, dialect: :engine)
    refute text =~ "240"

    eve =
      text
      |> String.split("\r\n")
      |> Enum.find(&String.contains?(&1, "Eve"))

    assert eve =~ "0000 - H"

    # And the engine leaves her out of round two because of it.
    parsed = Ainalrami.Trf.parse(text)
    pairs = Ainalrami.Pairing.pair_next_round(parsed.players, expected_rounds: 9)
    seated = pairs |> Enum.flat_map(&Tuple.to_list/1) |> Enum.reject(&is_nil/1)
    refute 5 in seated
  end

  test "a slice of the tournament carries no future bye - it is a historical excerpt" do
    {tournament, players} = configured()

    # A second played round, so that asking for round 1 alone is genuinely
    # a slice rather than the whole tournament.
    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})
    board(round, 1, players["Alice"], players["Bob"], "1-0")
    board(round, 2, players["Carol"], players["Dave"], "1-0")
    board(round, 3, players["Eve"], players["Frank"], "1-0")

    Repo.insert_all("byes", [
      %{
        tournament_id: tournament.id,
        player_id: players["Eve"].id,
        round: 2,
        type: "requested-half"
      }
    ])

    assert {:ok, text} = TrfExport.export(tournament, "1")
    refute text =~ "240"
  end

  test "administrative extra points survive, with the flag that makes them count" do
    {tournament, players} = configured(%{count_extra_points: true})
    {:ok, _} = Tournaments.update_player(players["Bob"], %{"extra_points" => 1.5})
    {:ok, _} = Tournaments.update_player(players["Dave"], %{"extra_points" => 1.5})

    {imported, _warnings, text} = round_trip(Repo.reload!(tournament))
    assert text =~ "\r\n299           1.5         2    4\r\n"

    assert imported.count_extra_points
    by_name = Map.new(imported_players(imported), &{&1.name, &1.extra_points})
    assert by_name["Bob"] == 1.5
    assert by_name["Dave"] == 1.5
    assert by_name["Alice"] == 0.0
  end

  test "extra points the tournament does not count stay out of the file" do
    {tournament, players} = configured(%{count_extra_points: false})
    {:ok, _} = Tournaments.update_player(players["Bob"], %{"extra_points" => 1.5})

    {imported, _, text} = round_trip(Repo.reload!(tournament))
    refute text =~ "299"
    refute imported.count_extra_points
  end

  test "Baku acceleration survives, because the method reproduces the file's own numbers" do
    {tournament, _} = configured(%{acceleration: "baku"})
    {imported, warnings, text} = round_trip(tournament)

    assert text =~ "\r\n250"
    assert text =~ "\r\n192 FIDE_DUTCH_2026_BAKU\r\n"
    assert imported.acceleration == "baku"
    assert warnings == []
  end

  test "virtual points Baku does not produce are not called Baku" do
    {tournament, _} = configured()
    {:ok, text} = TrfExport.export(tournament)
    # One point to rank 6 only - the bottom of the field, which Baku never
    # accelerates.
    text = text <> "250       1.0   1   1    6    6\r\n"

    assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope())
    assert imported.acceleration == "none"
    assert Enum.any?(warnings, &(&1[:kind] == :note and &1.text =~ "Baku method does not"))
  end

  test "a plain tournament round-trips with nothing to say" do
    {tournament, _} =
      configured(%{
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0,
        bye_value: 1.0,
        tiebreaks: ["BH"]
      })

    {imported, warnings, _} = round_trip(tournament)

    assert warnings == []
    assert imported.acceleration == "none"
    assert Tournaments.list_forbidden_pairings(imported.id) == []
    assert imported.tiebreaks == ["BH"]
  end
end
