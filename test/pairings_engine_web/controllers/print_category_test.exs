defmodule PairingsEngineWeb.PrintCategoryTest do
  @moduledoc """
  `?category=` on the print documents: one category's players and boards
  only, board numbers untouched, everything else byte-identical.
  """
  use PairingsEngineWeb.ConnCase

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  setup :register_and_log_in_user

  # Round 1: board 1 Amber - Beryl (category U1800), board 2 Cedric - Dora
  # (category U2000). Amber/Beryl are the only U1800 players.
  defp fixture(scope, pair_by_category?) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Cat Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    tournament =
      tournament
      |> Ecto.Changeset.change(
        categories: ["U1800", "U2000"],
        pair_by_category: pair_by_category?
      )
      |> Repo.update!()

    [a, b, c, d] =
      for {name, cat, n} <- [
            {"Amber", "U1800", 1},
            {"Beryl", "U1800", 2},
            {"Cedric", "U2000", 3},
            {"Dora", "U2000", 4}
          ] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          fide_rating: 1500 + n,
          pairing_number: n,
          categories: [cat],
          category: cat
        })
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: "1/2-1/2"
    })

    :ok = Tournaments.freeze_round_display_boards!(r1.id)
    tournament
  end

  for {label, pbc} <- [{"plain categories", false}, {"pair_by_category", true}] do
    describe label do
      test "pairings keep only the category's boards, numbers untouched", %{
        conn: conn,
        scope: scope
      } do
        t = fixture(scope, unquote(pbc))

        all = get(conn, ~p"/t/#{t.id}/print/pairings?round=1") |> html_response(200)
        assert all =~ "Cedric" and all =~ "Amber"

        html =
          get(conn, ~p"/t/#{t.id}/print/pairings?round=1&category=U2000") |> html_response(200)

        assert html =~ "Cedric" and html =~ "Dora"
        refute html =~ "Amber"
        assert html =~ "· U2000"
        # Board 2 stays board 2.
        assert html =~ ~s(<td class="num">2</td>)
        refute html =~ ~s(<td class="num">1</td>)
      end

      test "standings show only the category table, ranked in category", %{
        conn: conn,
        scope: scope
      } do
        t = fixture(scope, unquote(pbc))

        html = get(conn, ~p"/t/#{t.id}/print/standings?category=U2000") |> html_response(200)
        assert html =~ "Cedric" and html =~ "Dora"
        refute html =~ "Amber"
        refute html =~ "Category: U1800"
        assert html =~ "Category: U2000"
        assert html =~ "· U2000"
        # Exactly one standings table: no overall table in front.
        assert length(String.split(html, "<table")) == 2
      end

      test "the player list names only the category's players", %{conn: conn, scope: scope} do
        t = fixture(scope, unquote(pbc))

        html = get(conn, ~p"/t/#{t.id}/print/players?category=U1800") |> html_response(200)
        assert html =~ "Amber" and html =~ "Beryl"
        refute html =~ "Cedric"
        assert html =~ "(2)"
      end

      test "an unknown category is ignored and prints everything", %{conn: conn, scope: scope} do
        t = fixture(scope, unquote(pbc))

        plain = get(conn, ~p"/t/#{t.id}/print/players") |> html_response(200)
        odd = get(conn, ~p"/t/#{t.id}/print/players?category=Nope") |> html_response(200)
        # The CSP nonce differs per response; everything else must not.
        strip = &Regex.replace(~r/nonce="[^"]*"/, &1, "")
        assert strip.(plain) == strip.(odd)
      end
    end
  end

  test "a player tagged for two categories prints under the pairing category only", %{
    conn: conn,
    scope: scope
  } do
    t = fixture(scope, true)
    amber = Repo.get_by!(Player, tournament_id: t.id, name: "Amber")

    amber
    |> Ecto.Changeset.change(categories: ["U1800", "U2000"], category: "U1800")
    |> Repo.update!()

    html = get(conn, ~p"/t/#{t.id}/print/players?category=U2000") |> html_response(200)
    refute html =~ "Amber"
  end
end
