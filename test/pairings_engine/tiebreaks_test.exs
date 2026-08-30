defmodule PairingsEngine.TiebreaksTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Standings
  alias PairingsEngine.Tiebreaks
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  describe "the catalogue's own shape" do
    test "every entry declares a scope and whether it can be calculated" do
      for tb <- Tiebreaks.catalogue() do
        assert tb.scope in [:individual, :team, :both],
               "#{tb.code} has scope #{inspect(tb.scope)}"

        assert is_boolean(tb.available), "#{tb.code} has no availability"
      end
    end

    test "the three team-only breaks are the ones nothing here can calculate" do
      # Not a restatement of the table: this is the assertion to update when
      # team standings arrive, and it fails until the flag is flipped with
      # the implementation.
      assert Enum.sort(Tiebreaks.unavailable_codes()) == ~w(BB GP MP)
    end

    test "everything unavailable is team-scoped, since that is the reason" do
      for %{code: code, scope: scope} <- Tiebreaks.catalogue(),
          code in Tiebreaks.unavailable_codes() do
        assert scope == :team, "#{code} is unavailable but not team-scoped"
      end
    end

    test "selectable/0 is the catalogue minus what cannot be calculated" do
      assert Enum.map(Tiebreaks.selectable(), & &1.code) ==
               Enum.map(Tiebreaks.catalogue(), & &1.code) -- Tiebreaks.unavailable_codes()
    end

    test "an unavailable code still resolves to a name, because tournaments store it" do
      # SWAR files map tie-breaks by number and the FIDE team defaults name
      # all three, so a stored tournament can carry one; the picker hides it,
      # the catalogue must still know it.
      assert %{name: "Match points"} = Tiebreaks.get("MP")
    end
  end

  describe "against Standings" do
    setup do
      {:ok, tournament: seeded_tournament()}
    end

    test "every selectable code computes and none of them is dropped", %{tournament: t} do
      for %{code: code} <- Tiebreaks.selectable() do
        t = %{t | tiebreaks: [code]}

        assert Standings.dropped_tiebreaks(t) == [],
               "#{code} is offered in the picker but dropped by Standings"

        for entry <- Standings.standings(t) do
          assert is_number(entry.tiebreaks[code]), "#{code} produced no number"
        end
      end
    end

    test "every unavailable code is dropped, with a reason a page can print", %{tournament: t} do
      for code <- Tiebreaks.unavailable_codes() do
        t = %{t | tiebreaks: [code]}

        assert Standings.dropped_tiebreaks(t) == [code]
        assert Standings.dropped_tiebreaks_with_reasons(t) == [{code, :not_calculable}]
        assert Standings.effective_tiebreaks(t) == []
      end
    end

    test "a code dropped for both reasons is reported once, as not calculable", %{tournament: t} do
      # An unrated entrant puts ARO under Article 10; MP is uncalculable
      # regardless. Neither may be listed twice, and MP's reason is the one
      # the arbiter can act on.
      Repo.insert!(%Player{tournament_id: t.id, name: "Unrated", pairing_number: 3})
      t = %{t | tiebreaks: ["ARO", "MP"]}

      assert Standings.dropped_tiebreaks_with_reasons(t) ==
               [{"MP", :not_calculable}, {"ARO", :unrated_present}]
    end
  end

  # Two rated players and one finished game - enough for every individual
  # tie-break in the catalogue to have something to compute. Rated on
  # purpose: an unrated entrant would put ARO/AROC1 under C.07 Article 10,
  # which is a legitimate drop and would make "every selectable code
  # computes" fail for the wrong reason.
  defp seeded_tournament do
    t =
      Repo.insert!(%Tournament{
        name: "Catalogue",
        type: "swiss",
        rounds_count: 1,
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0,
        tiebreaks: []
      })

    alice =
      Repo.insert!(%Player{
        tournament_id: t.id,
        name: "Alice",
        pairing_number: 1,
        fide_rating: 2000
      })

    bob =
      Repo.insert!(%Player{
        tournament_id: t.id,
        name: "Bob",
        pairing_number: 2,
        fide_rating: 1800
      })

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    t
  end
end
