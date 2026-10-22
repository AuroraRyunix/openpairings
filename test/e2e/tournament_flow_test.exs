defmodule PairingsEngineWeb.E2E.TournamentFlowTest do
  @moduledoc """
  The evening an arbiter actually has: a new tournament, four players, round
  one paired, the results typed in, and the standings agreeing with them. All
  of it through the pages, in a browser, the way a person would click it.
  """
  use PairingsEngineWeb.E2ECase

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.Tournament

  @players [
    {"Anand, Viswanathan", "2750"},
    {"Carlsen, Magnus", "2830"},
    {"Hou, Yifan", "2630"},
    {"Polgar, Judit", "2690"}
  ]

  test "create a tournament, add players, pair a round, enter results", %{conn: conn} do
    {conn, _user} = sign_in(conn)

    conn =
      conn
      |> step("Create the tournament", fn conn ->
        conn
        |> assert_has("body .phx-connected")
        |> click_button("New tournament")
        |> within("#new-tournament-form", fn conn ->
          conn
          |> fill_in("Name", with: "Browser Open")
          |> fill_in("Rounds", with: "3")
          |> fill_in("Date from", with: Date.to_iso8601(Date.utc_today()), exact: false)
          |> click_button("Create tournament")
        end)
        |> assert_has("#players-page-header")
      end)

    tournament = Repo.get_by!(Tournament, name: "Browser Open")
    assert_path(conn, "/t/#{tournament.id}/players")

    conn =
      step(conn, "Add four players", fn conn ->
        conn = click(conn, "#add-player-open")

        @players
        |> Enum.reduce(conn, fn {name, rating}, conn ->
          conn
          |> within("#add-player-form", fn conn ->
            conn
            |> fill_in("Full name *", with: name)
            |> fill_in("FIDE rating", with: rating)
            |> click("#add-player-sex-m")
            |> click_button("Add player")
          end)
          |> assert_has("#players-table", text: name)
        end)
      end)

    conn =
      step(conn, "Pair round 1", fn conn ->
        conn
        |> visit("/t/#{tournament.id}/pairings")
        |> assert_has("body .phx-connected")
        |> click("#pair-round")
        |> assert_has("select[id^='result-select-']", count: 2)
      end)

    conn =
      step(conn, "Enter both results", fn conn ->
        conn
        |> select("Result, board 1:", option: "1-0", exact: false)
        |> assert_has("#result-select-#{pairing_id(tournament, 1)}[data-result='1-0']")
        |> select("Result, board 2:", option: "½-½", exact: false)
        |> assert_has("#result-select-#{pairing_id(tournament, 2)}[data-result='1/2-1/2']")
      end)

    step(conn, "The standings agree", fn conn ->
      conn
      |> visit("/t/#{tournament.id}/standings")
      |> assert_has("body .phx-connected")
      |> assert_has("td", text: "Carlsen, Magnus")
    end)

    # And the database, which is what the pages were for.
    results =
      tournament.id
      |> round_pairings(1)
      |> Enum.map(& &1.result)
      |> Enum.sort()

    assert results == ["1-0", "1/2-1/2"]
  end

  defp round_pairings(tournament_id, round_number) do
    import Ecto.Query

    Repo.all(
      from p in PairingsEngine.Tournaments.Pairing,
        join: r in assoc(p, :round),
        where: r.tournament_id == ^tournament_id and r.number == ^round_number,
        order_by: p.board
    )
  end

  defp pairing_id(tournament, board) do
    tournament.id |> round_pairings(1) |> Enum.find(&(&1.board == board)) |> Map.fetch!(:id)
  end
end
