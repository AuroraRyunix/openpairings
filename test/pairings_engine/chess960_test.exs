defmodule PairingsEngine.Chess960Test do
  @moduledoc """
  VCL4THP Q222: Chess960 - the standard numbering of the 960 starting
  positions, and the arbiter's draw of one per round.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Chess960, Repo}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  describe "numbering" do
    test "known positions" do
      assert Chess960.position(518) == "RNBQKBNR"
      assert Chess960.position(0) == "BBQNNRKR"
      assert Chess960.position(959) == "RKRNNQBB"
      assert Chess960.position(1) == "BQNBNRKR"
    end

    test "all 960 are different, legal and numbered back to themselves" do
      positions = for n <- 0..959, do: Chess960.position(n)
      assert length(Enum.uniq(positions)) == 960

      for {order, n} <- Enum.with_index(positions) do
        pieces = order |> String.graphemes() |> Enum.sort() |> Enum.join()
        assert pieces == "BBKNNQRR"

        [b1, b2] = for {"B", i} <- Enum.with_index(String.graphemes(order)), do: i
        assert rem(b1 + b2, 2) == 1, "#{order}: bishops on one colour"

        [r1, k, r2] =
          for {p, i} <- Enum.with_index(String.graphemes(order)), p in ["R", "K"], do: {p, i}

        assert [{"R", a}, {"K", b}, {"R", c}] = [r1, k, r2]
        assert a < b and b < c
        assert Chess960.number(order) == n
      end
    end

    test "an illegal setup has no number" do
      assert Chess960.number("RNBQQBNR") == :error
      assert Chess960.number("KRRBBNNQ") == :error
    end

    test "draw gives only numbers 0..959 and reaches both ends of the range often enough" do
      drawn = for _ <- 1..3000, do: Chess960.draw()
      assert Enum.all?(drawn, &(&1 in 0..959))
      # 3000 draws of 960: a stuck or narrow generator would show here.
      assert length(Enum.uniq(drawn)) > 800
    end
  end

  describe "the draw for a round" do
    setup do
      t = Repo.insert!(%Tournament{name: "960", type: "swiss", rounds_count: 3, chess960: true})
      Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "pairing"})
      %{t: t}
    end

    test "stores the position with the round, once", %{t: t} do
      assert {:ok, round} = Chess960.draw_for_round(t, 1, fn -> 518 end)
      assert round.chess960_position == 518
      assert Chess960.label(round) == "518 RNBQKBNR"

      assert {:error, :already_drawn} = Chess960.draw_for_round(t, 1, fn -> 0 end)
      assert Repo.get_by!(Round, tournament_id: t.id, number: 1).chess960_position == 518
    end

    test "a real draw is in range", %{t: t} do
      assert {:ok, %{chess960_position: n}} = Chess960.draw_for_round(t, 1)
      assert n in 0..959
    end

    test "needs the setting and a paired round", %{t: t} do
      assert {:error, :no_round} = Chess960.draw_for_round(t, 2)
      assert {:error, :not_enabled} = Chess960.draw_for_round(%{t | chess960: false}, 1)
    end
  end
end
