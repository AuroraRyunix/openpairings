defmodule PairingsEngine.PgnExportTest do
  # async: false - same reasoning as TrfExportTest: many writes contend on
  # SQLite's single writer lock under ExUnit parallelism.
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{PgnExport, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  defp fixture(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "PGN Export Test",
            "type" => "swiss",
            "rounds_count" => "2",
            "city" => "Ghent"
          },
          attrs
        )
      )

    alice =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice, A.",
        fide_rating: 2000,
        fide_id: 12345
      })

    bob =
      Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob, B.", national_rating: 1800})

    r1 =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "finished",
        date: "2026-07-14"
      })

    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 2,
      white_player_id: alice.id,
      black_player_id: nil,
      result: "bye"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: bob.id,
      black_player_id: alice.id,
      result: ""
    })

    # Every production call site freezes display labels immediately after a
    # round's pairings are inserted - do the same here so this fixture
    # matches reality.
    :ok = Tournaments.freeze_round_display_boards!(r1.id)
    :ok = Tournaments.freeze_round_display_boards!(r2.id)

    tournament
  end

  test "one game per non-bye pairing, with the Seven Tag Roster" do
    tournament = fixture(user_scope_fixture())

    text = PgnExport.export(tournament, 1)

    assert text =~ ~s([Event "PGN Export Test"])
    assert text =~ ~s([Site "Ghent"])
    assert text =~ ~s([Date "2026.07.14"])
    assert text =~ ~s([Round "1"])
    assert text =~ ~s([White "Alice, A."])
    assert text =~ ~s([Black "Bob, B."])
    assert text =~ ~s([Result "1-0"])
    assert text =~ "1-0\n"

    # Only one game (the bye is skipped) for round 1.
    assert length(String.split(text, "\n\n")) == 2
  end

  test "known ratings and FIDE ids are included, unknown ones are omitted" do
    tournament = fixture(user_scope_fixture())

    text = PgnExport.export(tournament, 1)

    assert text =~ ~s([WhiteElo "2000"])
    assert text =~ ~s([WhiteFideId "12345"])
    assert text =~ ~s([BlackElo "1800"])
    refute text =~ "BlackFideId"
  end

  test "venue used for Site when set, city as fallback, else \"?\"" do
    scope = user_scope_fixture()

    with_venue = fixture(scope, %{"venue" => "Main Hall"})
    assert PgnExport.export(with_venue, 1) =~ ~s([Site "Main Hall"])

    with_city_only = fixture(scope, %{"city" => "Bruges"})
    assert PgnExport.export(with_city_only, 1) =~ ~s([Site "Bruges"])

    with_neither = fixture(scope, %{"city" => ""})
    assert PgnExport.export(with_neither, 1) =~ ~s([Site "?"])
  end

  test "unset round date exports the placeholder" do
    tournament = fixture(user_scope_fixture())
    assert PgnExport.export(tournament, 2) =~ ~s([Date "????.??.??"])
  end

  test "an unplayed/blank result maps to Result \"*\"" do
    tournament = fixture(user_scope_fixture())
    text = PgnExport.export(tournament, 2)
    assert text =~ ~s([Result "*"])
    assert String.trim_trailing(text) |> String.ends_with?("*")
  end

  test "forfeits map to their nominal decisive result" do
    tournament = fixture(user_scope_fixture())

    round = Repo.get_by!(Round, tournament_id: tournament.id, number: 2)
    pairing = Repo.get_by!(Pairing, round_id: round.id, board: 1)
    Repo.update!(Ecto.Changeset.change(pairing, result: "1-0FF"))

    text = PgnExport.export(tournament, 2)
    assert text =~ ~s([Result "1-0"])
  end

  test "the legacy forfeit spellings map the same way as their FF twins" do
    # "+--" and "--+" are the older spelling of the same two single-sided
    # forfeits. Keizer.classify_result/2 and Standings both accept them, and
    # they reach this module from historical rows - here they fell to the
    # catch-all and exported as "*", an unknown result, while "1-0FF"
    # exported as decisive.
    for {stored, expected} <- [{"+--", "1-0"}, {"--+", "0-1"}] do
      tournament = fixture(user_scope_fixture())

      round = Repo.get_by!(Round, tournament_id: tournament.id, number: 2)
      pairing = Repo.get_by!(Pairing, round_id: round.id, board: 1)
      Repo.update!(Ecto.Changeset.change(pairing, result: stored))

      text = PgnExport.export(tournament, 2)

      assert text =~ ~s([Result "#{expected}"]),
             "#{stored} should export as #{expected}, the same as its FF twin"
    end
  end

  test "double forfeit has no single-sided result, so it maps to \"*\"" do
    tournament = fixture(user_scope_fixture())

    round = Repo.get_by!(Round, tournament_id: tournament.id, number: 2)
    pairing = Repo.get_by!(Pairing, round_id: round.id, board: 1)
    Repo.update!(Ecto.Changeset.change(pairing, result: "0-0FF"))

    text = PgnExport.export(tournament, 2)
    assert text =~ ~s([Result "*"])
  end

  test "nil round_number exports every round's games" do
    tournament = fixture(user_scope_fixture())

    text = PgnExport.export(tournament)

    assert text =~ ~s([Round "1"])
    assert text =~ ~s([Round "2"])
  end

  test "an unpaired round exports empty text" do
    tournament = fixture(user_scope_fixture())
    assert PgnExport.export(tournament, 3) == ""
  end

  test "board: false (the default) omits the Board tag entirely" do
    tournament = fixture(user_scope_fixture())
    refute PgnExport.export(tournament, 1) =~ "[Board "
  end

  test "board: true adds the display board number, right after Round" do
    tournament = fixture(user_scope_fixture())

    text = PgnExport.export(tournament, 1, board: true)
    lines = String.split(text, "\n")

    round_index = Enum.find_index(lines, &(&1 == ~s([Round "1"])))
    board_index = Enum.find_index(lines, &(&1 == ~s([Board "1"])))

    assert board_index == round_index + 1
  end

  # A round of `boards` games where the player on `pin_board` is pinned to
  # `fixed_board`, set BEFORE the freeze so it actually takes effect (see
  # PairingsEngine.PairingDisplay's moduledoc - it is never read live).
  defp pinned_fixture(scope, boards, pin_board, fixed_board) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "PGN Export Fixed Board Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    for board <- 1..boards do
      white =
        Repo.insert!(%Player{tournament_id: tournament.id, name: "White#{board}, W."})

      black =
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Black#{board}, B.",
          fixed_board: if(board == pin_board, do: fixed_board)
        })

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: board,
        white_player_id: white.id,
        black_player_id: black.id,
        result: "1-0"
      })
    end

    :ok = Tournaments.freeze_round_display_boards!(r1.id)

    tournament
  end

  defp board_tags(pgn), do: Regex.scan(~r/\[Board "([^"]+)"\]/, pgn) |> Enum.map(&Enum.at(&1, 1))

  test "board: true uses the REAL board number, not the display label - a fixed-table game keeps its engine board" do
    # The [Board] tag identifies the game within its round for a reader or
    # a database; it is not the arbiter's pairing sheet. The label moves
    # (and, on a colliding pin, duplicates), the real board doesn't. See
    # PgnExport.board_tag/1 for the full reasoning.
    tournament = pinned_fixture(user_scope_fixture(), 1, 1, 1001)

    text = PgnExport.export(tournament, 1, board: true)

    assert text =~ ~s([Board "1"])
    refute text =~ ~s([Board "1001"])
  end

  test "a fixed_board colliding with an ordinary board can't produce two [Board] tags in one round" do
    # `fixed_board` is allowed to collide with a real board number - the
    # maintainer's explicit decision (PairingsEngine.FixedBoardCollisionTest),
    # and harmless on a printed sheet where a human also reads the names.
    # In a PGN it is not harmless: fed the display label, real boards 1 and
    # 2 both came out tagged [Board "1"], leaving a reader keyed on
    # (Event, Round, Board) unable to tell the two games apart.
    tournament = pinned_fixture(user_scope_fixture(), 2, 2, 1)

    tags = tournament |> PgnExport.export(1, board: true) |> board_tags()

    assert tags == ["1", "2"]
    assert tags == Enum.uniq(tags), "two games in one round shared a [Board] tag"
  end

  test "every [Board] tag in a round is unique even with several fixed tables in play" do
    # Two pins that collide with each other AND with ordinary boards: real
    # boards 2 and 3 both pinned to 1, on a four-board round. By label that
    # is three rows numbered "1"; by real board it is 1, 2, 3, 4.
    scope = user_scope_fixture()
    tournament = pinned_fixture(scope, 4, 2, 1)

    round = Repo.get_by!(Round, tournament_id: tournament.id, number: 1)
    pairing = Repo.get_by!(Pairing, round_id: round.id, board: 3)

    Repo.get!(Player, pairing.black_player_id)
    |> Ecto.Changeset.change(fixed_board: 1)
    |> Repo.update!()

    :ok = Tournaments.freeze_round_display_boards!(round.id)

    tags = tournament |> PgnExport.export(1, board: true) |> board_tags()

    assert Enum.sort(tags) == ["1", "2", "3", "4"]
  end

  # Now trivially true (the export never consults PairingDisplay at all),
  # kept so that reintroducing a live `fixed_board` read here fails loudly.
  test "a fixed_board set AFTER the round is already paired has no effect on the export" do
    scope = user_scope_fixture()
    tournament = fixture(scope)

    text_before = PgnExport.export(tournament, 1, board: true)

    bob = Repo.get_by!(Player, tournament_id: tournament.id, name: "Bob, B.")
    Repo.update!(Ecto.Changeset.change(bob, fixed_board: 1001))

    text_after = PgnExport.export(tournament, 1, board: true)

    assert text_before == text_after
  end

  test "a control character in a name can't inject a PGN tag line" do
    scope = user_scope_fixture()
    tournament = fixture(scope)

    # A PGN tag is one line. Names have no format check, so a newline could
    # split the White tag and inject a forged one below it.
    hostile = Repo.get_by!(Player, tournament_id: tournament.id, name: "Alice, A.")
    Repo.update!(Ecto.Changeset.change(hostile, name: "Zoe\"]\n[Result \"0-1\"]\n[X \""))

    text = PgnExport.export(tournament, 1)
    lines = String.split(text, "\n")

    # No line is a forged Result tag: the real one is [Result "1-0"].
    refute Enum.any?(lines, &(&1 == ~s([Result "0-1"])))
    refute Enum.any?(lines, &String.starts_with?(&1, ~s([X )))
    # The name still appears, flattened onto the one White tag line.
    assert Enum.any?(lines, &(String.starts_with?(&1, ~s([White ")) and &1 =~ "Zoe"))
  end
end
