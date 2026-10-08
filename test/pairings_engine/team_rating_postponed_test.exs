defmodule PairingsEngine.TeamRatingPostponedTest do
  @moduledoc """
  The `310` team record of the file SENT FOR RATING (`TrfExport.export/3`
  with `for: :rating`) when a team round holds a postponed board. The board
  is written `0000 - Z` for both players (not played, rated later in the
  postponed-games file), so the record's match and game points count only the
  boards the file holds: the match is decided by the remaining boards, and a
  match with no board left in the file counts for nothing. The ordinary
  report (a copy, the engine's input) still counts the postponed board
  provisionally.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{PostponedGames, Repo, TeamStandings, Tournaments, TrfExport}

  defp setup_event do
    {t, _} =
      team_swiss(for(i <- 1..4, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10, 1980 - i * 10]}),
        rounds: 2,
        boards: 3,
        postponed_games: true
      )

    pair_next!(t)
    t = Repo.reload!(t)

    t =
      t
      |> Ecto.Changeset.change(
        start_date: "2026-09-01",
        end_date: "2026-09-05",
        round_dates: ["2026-09-01", "2026-09-02"]
      )
      |> Repo.update!()

    [m1, m2] =
      t |> TeamStandings.matches() |> Enum.filter(&(&1.round == 1 and not &1.bye?))

    name = fn id -> t.id |> Tournaments.list_teams() |> Enum.find(&(&1.id == id)) end
    enter!(t, 1, name.(m1.team_a_id).name, name.(m1.team_b_id).name, ["1-0", "0-1", "*"])
    enter!(t, 1, name.(m2.team_a_id).name, name.(m2.team_b_id).name, ["*", "*", "*"])
    {Repo.reload!(t), m1, m2}
  end

  defp figures(text, team) do
    line =
      text
      |> String.split("\r\n")
      |> Enum.find(
        &(String.starts_with?(&1, "310") and
            String.slice(&1, 4, 3) |> String.trim() == "#{team.pairing_number}")
      )

    num = fn from, len -> line |> String.slice(from, len) |> String.trim() end
    {num.(54, 6), num.(61, 6), num.(68, 3)}
  end

  test "the rating file's 310 counts the boards the file holds; a match left with none counts for nothing" do
    {t, m1, m2} = setup_event()
    teams = Map.new(Tournaments.list_teams(t.id), &{&1.id, &1})
    # FIDE mode makes no TRF with a game open (Q169): record it as not
    # played in this event first, as the arbiter now has to.
    t = PairingsEngine.PostponedHelpers.report_open_games_not_played!(t)

    {:ok, rating} = TrfExport.export(t, [1], for: :rating)
    {:ok, copy} = TrfExport.export(t, [1])

    # Match 1: one board postponed, the two others won by team A.
    assert {"2.0", "2.0", ""} = figures(rating, teams[m1.team_a_id])
    assert {"0.0", "0.0", ""} = figures(rating, teams[m1.team_b_id])

    # Match 2: every board postponed - no match in this file.
    assert {"0.0", "0.0", ""} = figures(rating, teams[m2.team_a_id])
    assert {"0.0", "0.0", ""} = figures(rating, teams[m2.team_b_id])

    # Everything else counts the postponed board provisionally, as before.
    assert {"2.0", "2.5", _} = figures(copy, teams[m1.team_a_id])
    assert {"1.0", "1.5", _} = figures(copy, teams[m2.team_a_id])

    # Sent: the same file; a file without a postponed board is untouched.
    assert {:ok, %{file: sent}} =
             PostponedGames.send_rounds(
               t,
               [1],
               &TrfExport.export(&1, [1], for: :rating),
               acknowledged: [:round_sent_before]
             )

    assert {"2.0", "2.0", ""} = figures(sent, teams[m1.team_a_id])
  end
end
