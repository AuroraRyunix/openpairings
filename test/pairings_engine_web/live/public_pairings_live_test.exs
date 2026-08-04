defmodule PairingsEngineWeb.PublicPairingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  # No login — the public page needs no `register_and_log_in_user` setup.

  test "has no app chrome (topbar tabs/accent picker/sign-in), shows tempo when set", %{
    conn: conn
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Chrome Test",
        "type" => "swiss",
        "rate_of_play" => "15 min + 10 sec/move"
      })

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    refute html =~ "accent-picker"
    refute html =~ "topbar-signin"
    assert html =~ "theme-switch"
    assert html =~ "Tempo: 15 min + 10 sec/move"
  end

  test "renders a round's pairings sorted by board number regardless of insertion order", %{
    conn: conn
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Board Order Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [a, b, c, d, e, f] =
      for name <- [
            "Boardonealice",
            "Boardonebob",
            "Boardtwocarol",
            "Boardtwodave",
            "Boardthreeeve",
            "Boardthreefred"
          ] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 3,
      white_player_id: e.id,
      black_player_id: f.id,
      result: ""
    })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: ""
    })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    positions =
      for name <- ["Boardonealice", "Boardtwocarol", "Boardthreeeve"],
          do: :binary.match(html, name) |> elem(0)

    assert positions == Enum.sort(positions), "expected boards 1, 2, 3 top to bottom"
  end

  test "shows byes-table rows (SWAR-imported/round-specific absentee byes) alongside the round's pairings",
       %{
         conn: conn
       } do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Byes Display Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [a, b, absentee] =
      for name <- ["A", "B", "Absentee"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: ""
    })

    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: absentee.id, round: 1, type: "requested-half"}
    ])

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    assert html =~ "Absentee"
    assert html =~ "requested half-point bye"
  end
end
