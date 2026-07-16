defmodule PairingsEngineWeb.AuditLoggingTest do
  @moduledoc """
  Asserts representative LiveView `handle_event` clauses write the expected
  `audit_logs` row (right action + plausible details) right after their
  context call succeeds.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Round, Pairing}

  setup :register_and_log_in_user

  defp setup_tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "T",
            "type" => "swiss",
            "start_date" => "2026-07-01",
            "rounds_count" => "5",
            "round_dates" => List.duplicate("2026-07-01", 5),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL",
            "rate_of_play" => "90 min + 30 sec/move"
          },
          attrs
        )
      )

    t
  end

  defp actions(t), do: t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)

  test "editing a player logs player.updated with a before/after diff", %{conn: conn, scope: scope} do
    t = setup_tournament(scope)
    {:ok, player} = Tournaments.create_player(t.id, %{"name" => "Alice", "fide_rating" => "1800"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

    render_click(lv, "edit_player", %{"id" => to_string(player.id)})

    lv
    |> form("form", player: %{"name" => "Alice", "fide_rating" => "1850"})
    |> render_submit()

    # Drain the self-broadcast (update_player broadcasts :players on the
    # tournament topic this lv subscribes to) before teardown, so a late
    # handle_info reload can't leak a connection and busy the next test.
    render(lv)

    row = t.id |> Audit.list_for_tournament(action: "player.updated") |> List.first()
    assert row
    assert row.details["player_name"] == "Alice"
    assert row.details["changed_fields"]["fide_rating"] == [1800, 1850]
  end

  test "creating a player logs player.created", %{conn: conn, scope: scope} do
    t = setup_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

    render_click(lv, "add", %{})

    lv
    |> form("form", player: %{"name" => "Zoe", "fide_rating" => "1500"})
    |> render_submit()

    render(lv)

    assert "player.created" in actions(t)
  end

  test "saving settings logs tournament.settings_updated with the changed field", %{
    conn: conn,
    scope: scope
  } do
    t = setup_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")

    lv
    |> form("form[phx-submit=save]", %{"tournament" => %{"venue" => "Grand Hall"}})
    |> render_submit()

    render(lv)

    row = t.id |> Audit.list_for_tournament(action: "tournament.settings_updated") |> List.first()
    assert row
    assert row.details["changed_fields"]["venue"] == ["", "Grand Hall"]
  end

  test "entering a result logs pairing.result_entered", %{conn: conn, scope: scope} do
    t = setup_tournament(scope)
    {:ok, p1} = Tournaments.create_player(t.id, %{"name" => "Alice", "pairing_number" => "1"})
    {:ok, p2} = Tournaments.create_player(t.id, %{"name" => "Bob", "pairing_number" => "2"})

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "playing"})

    pairing =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: p1.id,
        black_player_id: p2.id,
        result: ""
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    render_click(lv, "result", %{"pairing-id" => to_string(pairing.id), "result" => "1-0"})

    render(lv)

    row = t.id |> Audit.list_for_tournament(action: "pairing.result_entered") |> List.first()
    assert row
    assert row.details["board"] == 1
    assert row.details["to"] == "1-0"
    assert row.details["white"] == "Alice"
  end

  @tag :javafo
  test "pairing a round logs a rich pairing.round_paired entry", %{conn: conn, scope: scope} do
    t = setup_tournament(scope)

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    render_click(lv, "pair", %{})

    render(lv)

    row = t.id |> Audit.list_for_tournament(action: "pairing.round_paired") |> List.first()
    assert row
    assert row.details["round"] == 1
    assert row.details["board_count"] == 2
    assert row.details["pairing_system"] == "swiss"
    assert is_list(row.details["boards"])
  end
end
