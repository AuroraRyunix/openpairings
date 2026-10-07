defmodule PairingsEngine.HalfByesTest do
  @moduledoc """
  VCL4THP Q174 and Q175: a second or later half-point bye (C.05:6.7.4) needs
  the arbiter's explicit confirmation, and a player marked not eligible gets
  none.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{HalfByes, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  # Absences score a draw, i.e. an absence IS a half-point bye.
  defp tournament(abs_value \\ 0.5) do
    Repo.insert!(%Tournament{
      name: "Half byes",
      type: "swiss",
      rounds_count: 7,
      abs_value: abs_value
    })
  end

  defp player(t, attrs \\ %{}) do
    Repo.insert!(struct(%Player{tournament_id: t.id, name: "Ann"}, attrs))
  end

  test "an absence is a half-point bye only where the tournament scores it as half" do
    assert HalfByes.half_rounds(tournament(0.5), "2,4") == [2, 4]
    assert HalfByes.half_rounds(tournament(nil), "2,4") == []
    assert HalfByes.half_rounds(tournament(1.0), "2,4") == []
  end

  test "the count cap of the absence points decides which absences are half-point byes" do
    t = %{tournament() | abs_nbfois: 1}
    assert HalfByes.half_rounds(t, "2,4") == [2]
  end

  describe "second half-point bye (Q174)" do
    test "the first is not warned about, the second is" do
      t = tournament()
      p = player(t)

      assert Tournaments.second_half_bye_rounds(p, %{"absent_rounds" => "3"}) == []
      assert Tournaments.second_half_bye_rounds(p, %{"absent_rounds" => "3,5"}) == [3, 5]

      {:ok, p} = Tournaments.update_player(p, %{"absent_rounds" => "3"})
      assert Tournaments.second_half_bye_rounds(p, %{"absent_rounds" => "3,5"}) == [5]
      # Leaving it as it is adds nothing.
      assert Tournaments.second_half_bye_rounds(p, %{"absent_rounds" => "3"}) == []
      assert Tournaments.second_half_bye_rounds(p, %{"name" => "Ann B"}) == []
    end

    test "a requested half-point bye already in the byes table counts as the first" do
      t = tournament()
      p = player(t)

      Repo.insert_all("byes", [
        %{tournament_id: t.id, player_id: p.id, round: 1, type: "requested-half"}
      ])

      assert Tournaments.second_half_bye_rounds(p, %{"absent_rounds" => "4"}) == [4]
    end

    test "nothing is warned when absences do not score as half" do
      p = player(tournament(nil))
      assert Tournaments.second_half_bye_rounds(p, %{"absent_rounds" => "3,5"}) == []
    end

    test "the dialog's save waits for the confirmation, a plain update does not" do
      t = tournament()
      p = player(t)

      assert {:error, {:needs_acknowledgement, [:second_half_bye]}} =
               Tournaments.update_player(p, %{"absent_rounds" => "3,5"}, [])

      assert Repo.reload!(p).absent_rounds == ""

      assert {:ok, saved} =
               Tournaments.update_player(p, %{"absent_rounds" => "3,5"},
                 acknowledged: [:second_half_bye]
               )

      assert saved.absent_rounds == "3,5"
    end
  end

  describe "not eligible for half-point byes (Q175)" do
    test "refuses a half-point absence for a marked player" do
      t = tournament()
      p = player(t, %{no_half_bye: true})

      assert {:error, changeset} = Tournaments.update_player(p, %{"absent_rounds" => "3"})
      assert %{absent_rounds: [message]} = errors_on(changeset)
      assert message =~ "not eligible for half-point byes"
      assert Repo.reload!(p).absent_rounds == ""
    end

    test "refuses marking a player who already has one" do
      t = tournament()
      p = player(t, %{absent_rounds: "3"})

      assert {:error, _} = Tournaments.update_player(p, %{"no_half_bye" => "true"})
      refute Repo.reload!(p).no_half_bye
    end

    test "a marked player may be absent where absences do not score as half" do
      p = player(tournament(nil), %{no_half_bye: true})
      assert {:ok, _} = Tournaments.update_player(p, %{"absent_rounds" => "3"})
    end

    test "an unrelated edit of a marked player with a stored absence still saves" do
      t = tournament()
      p = player(t, %{no_half_bye: true, absent_rounds: "3"})
      assert {:ok, _} = Tournaments.update_player(p, %{"club" => "Elsewhere"})
    end

    test "the mark is exported with the player" do
      assert :no_half_bye in PairingsEngine.TournamentExport.player_fields()
    end
  end
end
