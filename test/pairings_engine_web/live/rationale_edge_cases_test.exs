defmodule PairingsEngineWeb.RationaleEdgeCasesTest do
  @moduledoc """
  The audit trail and the pairing-rationale page were reported crashing
  "sometimes" on real tournaments. Both go through
  `PairingsEngine.PairingRationale.for_round/2`, and every guard in that
  module reads correctly, so this hunts for the shape that isn't guarded
  rather than re-reading the code.

  Each test builds a round that a real tournament can produce but the
  existing suite never does, and asserts only that the two pages RENDER —
  what they say about an odd round is a separate question from whether
  they survive it.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Round, as: RoundSchema
  alias PairingsEngine.Tournaments.Pairing, as: PairingSchema

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Edge", "type" => "swiss"}, attrs)
      )

    t
  end

  defp player(t, name) do
    {:ok, p} = Tournaments.create_player(t.id, %{"name" => name})
    p
  end

  defp round(t, number, status \\ "playing") do
    Repo.insert!(%RoundSchema{tournament_id: t.id, number: number, status: status})
  end

  defp board(r, n, white, black, result) do
    Repo.insert!(%PairingSchema{
      round_id: r.id,
      board: n,
      white_player_id: white && white.id,
      black_player_id: black && black.id,
      result: result
    })
  end

  # Both pages, since they share for_round/2 and a crash in either is the
  # bug being hunted.
  defp render_both(conn, t, round_number) do
    {:ok, _lv, explain} = live(conn, ~p"/t/#{t.id}/pairings/#{round_number}/explain")
    {:ok, _lv, audit} = live(conn, ~p"/t/#{t.id}/audit")
    {explain, audit}
  end

  test "a round row that exists with no pairings at all", %{conn: conn, scope: scope} do
    t = tournament(scope)
    player(t, "Alice")
    round(t, 1)

    assert {_, _} = render_both(conn, t, 1)
  end

  test "a bye recorded with an empty result rather than \"bye\"", %{conn: conn, scope: scope} do
    t = tournament(scope)
    a = player(t, "Alice")
    r = round(t, 1)
    board(r, 1, a, nil, "")

    assert {_, _} = render_both(conn, t, 1)
  end

  test "a double forfeit", %{conn: conn, scope: scope} do
    t = tournament(scope)
    a = player(t, "Alice")
    b = player(t, "Bob")
    r = round(t, 1)
    board(r, 1, a, b, "1-0FF")

    assert {_, _} = render_both(conn, t, 1)
  end

  test "result \"bye\" with a real opponent in the black seat", %{conn: conn, scope: scope} do
    t = tournament(scope)
    a = player(t, "Alice")
    b = player(t, "Bob")
    r = round(t, 1)
    board(r, 1, a, b, "bye")

    assert {_, _} = render_both(conn, t, 1)
  end

  test "a player registered after round 1, with no games at all", %{conn: conn, scope: scope} do
    t = tournament(scope)
    a = player(t, "Alice")
    b = player(t, "Bob")

    r1 = round(t, 1)
    board(r1, 1, a, b, "1-0")

    late = player(t, "Zoe")
    r2 = round(t, 2)
    board(r2, 1, a, late, "")
    board(r2, 2, b, nil, "bye")

    assert {_, _} = render_both(conn, t, 2)
  end

  test "an unplayed round whose players have no prior round at all", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)
    a = player(t, "Alice")
    b = player(t, "Bob")

    # Round 2 exists; round 1 never did. Real after a round is deleted.
    r2 = round(t, 2)
    board(r2, 1, a, b, "")

    assert {_, _} = render_both(conn, t, 2)
  end

  test "a white seat left empty", %{conn: conn, scope: scope} do
    t = tournament(scope)
    b = player(t, "Bob")
    r = round(t, 1)
    board(r, 1, nil, b, "")

    assert {_, _} = render_both(conn, t, 1)
  end

  test "two boards naming the same player", %{conn: conn, scope: scope} do
    t = tournament(scope)
    a = player(t, "Alice")
    b = player(t, "Bob")
    c = player(t, "Carol")
    r = round(t, 1)
    board(r, 1, a, b, "1-0")
    board(r, 2, a, c, "0-1")

    assert {_, _} = render_both(conn, t, 1)
  end

  test "a Keizer tournament", %{conn: conn, scope: scope} do
    t = tournament(scope, %{"pairing_system" => "keizer"})
    a = player(t, "Alice")
    b = player(t, "Bob")
    r = round(t, 1)
    board(r, 1, a, b, "1-0")

    assert {_, _} = render_both(conn, t, 1)
  end

  # Every action code the app can emit, with details the renderer cannot
  # rely on. `describe/2` has a catch-all for UNKNOWN actions, but a KNOWN
  # action whose details are missing a key its clause reads would crash the
  # whole page -- and only for tournaments that happen to contain such an
  # entry, which is exactly what "sometimes" looks like.
  @all_actions [
    "player.created",
    "player.updated",
    "player.deleted",
    "player.ratings_refreshed",
    "pairing.round_paired",
    "pairing.result_entered",
    "pairing.result_changed",
    "pairing.round_deleted",
    "pairing.results_imported",
    "pairing.result_clear_attempted",
    "tournament.settings_updated",
    "tournament.created",
    "tournament.deleted",
    "tournament.restored",
    "tournament.purged",
    "logo.uploaded",
    "logo.cleared",
    "forbidden_pairing.added",
    "forbidden_pairing.removed",
    "category.created",
    "category.removed",
    "standings.manual_reorder",
    "standings.manual_ranking_enabled",
    "standings.manual_ranking_disabled",
    "standings.manual_reseeded",
    "standings.extra_points_applied",
    "import.swar",
    "import.trf",
    "import.json",
    "collaborator.invited",
    "collaborator.accepted",
    "collaborator.declined",
    "collaborator.removed",
    "snapshot.manual",
    "snapshot.restored",
    "categories.toggled",
    "pair_by_category.toggled",
    "public_pages.toggled",
    "public_pages.link_rotated",
    "registration.toggled"
  ]

  test "the audit page renders every action code with empty details", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)

    for action <- @all_actions do
      PairingsEngine.Audit.log(t.id, scope, action, %{})
    end

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")
    assert html =~ "Audit"
  end

  test "the audit page renders every action code with nil details", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)

    for action <- @all_actions do
      PairingsEngine.Audit.log(t.id, scope, action, nil)
    end

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")
    assert html =~ "Audit"
  end

  test "the audit page renders details of the wrong SHAPE", %{conn: conn, scope: scope} do
    t = tournament(scope)

    # Values a JSON round-trip or an older schema version can leave behind:
    # a string where a count is expected, a list where a map is, nulls.
    for action <- @all_actions do
      PairingsEngine.Audit.log(t.id, scope, action, %{
        "round" => nil,
        "board_count" => "3",
        "bye_count" => nil,
        "floater_count" => "x",
        "changed_fields" => [],
        "allocated_bye" => "someone",
        "label" => 42,
        "restored_to" => %{},
        "player_name" => nil
      })
    end

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")
    assert html =~ "Audit"
  end

  # Size is the dimension the rest of the suite holds constant: every other
  # test here is 2-5 players. A LiveView that takes too long to mount looks
  # to the user exactly like "server error", and would only ever happen on
  # the big tournaments -- which is what "sometimes" would mean.
  test "a 150-player, 5-round tournament renders the rationale in reasonable time", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)

    players =
      for i <- 1..150 do
        {:ok, p} =
          Tournaments.create_player(t.id, %{
            "name" => "Player #{String.pad_leading(to_string(i), 3, "0")}",
            "fide_rating" => to_string(2400 - i * 5)
          })

        p
      end

    for rn <- 1..5 do
      r = round(t, rn)

      players
      |> Enum.shuffle()
      |> Enum.chunk_every(2)
      |> Enum.with_index(1)
      |> Enum.each(fn
        {[w, b], n} -> board(r, n, w, b, Enum.random(["1-0", "0-1", "1/2-1/2"]))
        {[w], n} -> board(r, n, w, nil, "bye")
      end)
    end

    {us, {:ok, _lv, html}} =
      :timer.tc(fn -> live(conn, ~p"/t/#{t.id}/pairings/5/explain") end)

    assert html =~ "Round 5"

    ms = div(us, 1000)
    IO.puts("
  [150 players, round 5] rationale page mounted in #{ms} ms")
    assert ms < 15_000, "rationale page took #{ms} ms — a real tournament would time out"
  end
end
