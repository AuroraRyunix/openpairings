defmodule PairingsEngine.PlayerCardTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.PlayerCard

  @tournament %{points_win: 1.0, points_draw: 0.5, points_loss: 0.0}

  describe "result_label/2" do
    test "actual results over the board" do
      assert PlayerCard.result_label(%{opponent_id: 2, played: true, points: 1.0}, @tournament) ==
               "1"

      assert PlayerCard.result_label(%{opponent_id: 2, played: true, points: 0.5}, @tournament) ==
               "½"

      assert PlayerCard.result_label(%{opponent_id: 2, played: true, points: 0.0}, @tournament) ==
               "0"
    end

    test "forfeits (opponent existed, game unplayed, not voluntary)" do
      game = %{opponent_id: 2, played: false, voluntary: false, points: 1.0}
      assert PlayerCard.result_label(game, @tournament) == "1FF"

      game = %{opponent_id: 2, played: false, voluntary: false, points: 0.0}
      assert PlayerCard.result_label(game, @tournament) == "0FF"
    end

    test "byes (no opponent) without a :bye_type fall back to the point-value heuristic" do
      assert PlayerCard.result_label(%{opponent_id: nil, points: 1.0}, @tournament) == "1 bye"
      assert PlayerCard.result_label(%{opponent_id: nil, points: 0.5}, @tournament) == "½ bye"
      assert PlayerCard.result_label(%{opponent_id: nil, points: 0.0}, @tournament) == "0 bye"
    end

    test "byes carrying a :bye_type are labelled by kind, not by point value" do
      # SWAR-3-2-1-style custom scoring where the awarded point values
      # collide across kinds: win 2.0 / draw 1.0 / loss 0.0, presence
      # points 1.0 (== points_draw!), bye 2.0.
      t = %{points_win: 2.0, points_draw: 1.0, points_loss: 0.0}

      # A presence-valued requested-ZERO bye awards 1.0 == points_draw; the
      # old points-only heuristic mislabelled it "½ bye". The kind wins.
      game = %{opponent_id: nil, points: 1.0, bye_type: "requested-zero"}
      assert PlayerCard.result_label(game, t) == "0 bye"

      game = %{opponent_id: nil, points: 1.0, bye_type: "requested-half"}
      assert PlayerCard.result_label(game, t) == "½ bye"

      # An absence is labelled by what it actually PAID. It read "0 bye"
      # while nothing could pay anything else; now that a tournament can
      # award half a point for a round sat out, that label would be a lie.
      # Read from the value itself, not compared against this tournament's
      # 2/1/0 - half a point is neither its draw nor its loss.
      game = %{opponent_id: nil, points: 0.5, bye_type: "absent"}
      assert PlayerCard.result_label(game, t) == "½ bye"

      game = %{opponent_id: nil, points: 0.0, bye_type: "absent"}
      assert PlayerCard.result_label(game, t) == "0 bye"

      # Pairing-allocated keeps the point-value number (it tracks what the
      # bye actually pays): a full 3.0 bye (bye_value + presence) is "1 bye",
      # a half-point pairing bye is "½ bye".
      game = %{opponent_id: nil, points: 3.0, bye_type: "pairing-allocated"}
      assert PlayerCard.result_label(game, t) == "1 bye"

      game = %{opponent_id: nil, points: 1.0, bye_type: "pairing-allocated"}
      assert PlayerCard.result_label(game, t) == "½ bye"

      # Defensive: an explicit nil bye_type behaves like a missing key.
      game = %{opponent_id: nil, points: 0.0, bye_type: nil}
      assert PlayerCard.result_label(game, t) == "0 bye"
    end

    test "voluntary unplayed round with an opponent renders blank" do
      game = %{opponent_id: 2, played: false, voluntary: true, points: 0.5}
      assert PlayerCard.result_label(game, @tournament) == ""
    end
  end

  describe "colour_label/1" do
    test "maps :w/:b/nil to W/B/-" do
      assert PlayerCard.colour_label(%{colour: :w}) == "W"
      assert PlayerCard.colour_label(%{colour: :b}) == "B"
      assert PlayerCard.colour_label(%{colour: nil}) == "-"
    end
  end

  describe "float_symbol/2" do
    test "^ when the opponent had more points, v when fewer, - when equal or no opponent" do
      assert PlayerCard.float_symbol(2.0, 3.0) == "^"
      assert PlayerCard.float_symbol(3.0, 2.0) == "v"
      assert PlayerCard.float_symbol(2.0, 2.0) == "-"
      assert PlayerCard.float_symbol(2.0, nil) == "-"
    end
  end

  describe "points_before/2" do
    test "sums only rounds strictly before the given round" do
      games = [
        %{round: 1, points: 1.0},
        %{round: 2, points: 0.5},
        %{round: 3, points: 1.0}
      ]

      assert PlayerCard.points_before(games, 1) == 0.0
      assert PlayerCard.points_before(games, 3) == 1.5
      assert PlayerCard.points_before(games, 4) == 2.5
    end
  end

  describe "opponent_rating/1" do
    test "prefers a positive national rating, falls back to FIDE rating" do
      assert PlayerCard.opponent_rating(%{national_rating: 1900, fide_rating: 2000}) == 1900
      assert PlayerCard.opponent_rating(%{national_rating: 0, fide_rating: 2000}) == 2000
      assert PlayerCard.opponent_rating(%{national_rating: nil, fide_rating: 1800}) == 1800
    end
  end

  describe "rows/3 and totals/2" do
    test "builds one row per game, sorted by round, with opponent context resolved" do
      alice_games = [
        %{round: 1, opponent_id: 2, colour: :w, points: 1.0, played: true, voluntary: false},
        %{round: 2, opponent_id: nil, colour: nil, points: 0.5, played: false, voluntary: true}
      ]

      bob_games = [
        %{round: 1, opponent_id: 1, colour: :b, points: 0.0, played: true, voluntary: false}
      ]

      alice = %{
        player: %{
          id: 1,
          name: "Alice",
          pairing_number: 1,
          federation: "BEL",
          title: "",
          national_rating: 1900,
          fide_rating: 0,
          national_id: "123",
          club_number: 7
        },
        games: alice_games,
        points: 1.5,
        total: 1.5,
        rank: 1
      }

      bob = %{
        player: %{
          id: 2,
          name: "Bob",
          pairing_number: 2,
          federation: "NED",
          title: "FM",
          national_rating: 0,
          fide_rating: 2000,
          national_id: "",
          club_number: nil
        },
        games: bob_games,
        points: 0.0,
        total: 0.0,
        rank: 2
      }

      by_id = %{1 => alice, 2 => bob}
      rows = PlayerCard.rows(alice, by_id, @tournament)

      assert length(rows) == 2
      [round1, round2] = rows

      assert round1.round == 1
      assert round1.opponent_name == "Bob"
      assert round1.opponent_elo == 2000
      assert round1.opponent_total == 0.0
      assert round1.result == "1"
      assert round1.colour == "W"
      assert round1.float == "-"

      assert round2.round == 2
      assert round2.opponent_name == nil
      assert round2.result == "½ bye"
      assert round2.colour == "-"
      assert round2.float == "-"

      totals = PlayerCard.totals(rows, alice)
      assert totals.opponent_total == 0.0
      assert totals.own_total == 1.5
    end
  end

  describe "header/1" do
    test "includes all pieces when present" do
      entry = %{
        rank: 1,
        player: %{
          pairing_number: 3,
          national_id: "12345",
          name: "Doe, Jane",
          national_rating: 1900,
          club_number: 7
        }
      }

      assert PlayerCard.header(entry) ==
               "Ranking:1 - (N°:3) - 12345: Doe, Jane. N-Elo:1900 Club:7"
    end

    test "omits missing pieces gracefully" do
      entry = %{
        rank: 4,
        player: %{
          pairing_number: 9,
          national_id: "",
          name: "Smith, John",
          national_rating: 0,
          club_number: nil
        }
      }

      assert PlayerCard.header(entry) == "Ranking:4 - (N°:9) - Smith, John."
    end
  end
end
