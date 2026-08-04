defmodule PairingsEngineWeb.NormsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  test "renders download links for all four forms and lists players", %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})

    # IT3/FA1 are gated on every official having a FIDE ID, plus chief
    # arbiter/organizer e-mail (see `report_blockers/1` — FIDE bounces a
    # report it can't identify an arbiter from, or that's missing the
    # e-mails its own template's privacy notice requires), so a tournament
    # that's expected to render live download links has to have all of it.
    {:ok, tournament} =
      Tournaments.update_tournament(tournament, %{
        "chief_arbiter" => "Cornet, Luc",
        "organizer" => "Jane Organizer",
        "officials" => %{
          "chief_arbiter_fide_id" => "205494",
          "chief_arbiter_email" => "arbiter@example.com",
          "organizer_email" => "organizer@example.com"
        }
      })

    {:ok, _player} = Tournaments.create_player(tournament.id, %{"name" => "Doe, Jane"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    assert html =~ "Norms &amp; FIDE reports"
    assert html =~ ~s(href="/t/#{tournament.id}/norms/it3")
    assert html =~ ~s(action="/t/#{tournament.id}/norms/fa1")
    assert html =~ ~s(href="/t/#{tournament.id}/norms/it4")
    assert html =~ "Doe, Jane"
    assert html =~ "No players have a claimed title yet"

    # The automatic B.01 judgment column renders for every player — with no
    # games played yet, the verdict is the honest "no counted games".
    assert html =~ "Computed (B.01)"
    assert html =~ "no counted games"
  end

  test "editing a player's norm data persists it and it then shows up as an IT4 candidate", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})

    {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Doe, Jane"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    lv |> element("button", "Edit norm data") |> render_click()

    html =
      lv
      |> form("form[phx-submit=save_norm]", %{
        "player" => %{
          "norm_data" => %{
            "title_claimed" => "IM",
            "norm_description" => "IM norm",
            "medal_percent" => "",
            "event_group" => "",
            "fed_participating" => "",
            "fed_members" => "",
            "remarks" => ""
          }
        }
      })
      |> render_submit()

    refute html =~ "No players have a claimed title yet"
    assert html =~ "IM norm"

    # "save_norm" broadcasts :players on the tournament topic and this `lv`
    # is subscribed to its own tournament (see NormsLive's mount) —
    # render_submit/1 only waits for the direct reply to the "save_norm"
    # event, not for that self-broadcast's handle_info reload, which lands
    # in the mailbox microseconds later and runs its own Repo query. Drain
    # it with a synchronous render/1 before the test (and this `lv`'s
    # teardown) proceeds (see the same fix in sharing_test.exs).
    render(lv)

    updated = Tournaments.get_player!(player.tournament_id, player.id)
    assert updated.norm_data["title_claimed"] == "IM"
  end

  test "the norm-judgment table sorts players who've played games ahead of ones who haven't, regardless of roster order",
       %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Norms Sort LV", "type" => "swiss"})

    # Inserted in an order that would put "Zed" before "Alice" under any
    # incidental default (pairing_number/insertion) ordering — the sort has
    # to be doing real work to put HasGames ahead of NoGames here.
    has_games =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Zed, HasGames",
        pairing_number: 1
      })

    _no_games =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice, NoGames",
        pairing_number: 2
      })

    opponent =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Opponent, Third",
        pairing_number: 3
      })

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: has_games.id,
      black_player_id: opponent.id,
      result: "1-0"
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    # Player names also appear earlier on the page (the IT3 counts-explain
    # breakdown lists every player unsorted) — anchor the search to the
    # norm-judgment table itself so the comparison is actually of its order,
    # not whichever section happens to mention a name first.
    {table_start, _} = :binary.match(html, "Players - title-norm judgment")
    table_html = binary_part(html, table_start, byte_size(html) - table_start)

    {has_games_pos, _} = :binary.match(table_html, "Zed, HasGames")
    {no_games_pos, _} = :binary.match(table_html, "Alice, NoGames")

    assert has_games_pos < no_games_pos
  end

  describe "Combined report (festival) card" do
    test "shows a hint instead of checkboxes when the user has no other tournaments", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      assert html =~ "Combined report (festival)"
      assert html =~ "You have no other tournaments to combine this one with."
    end

    test "lists the user's other tournaments as checkboxes, and only shows the combined downloads once one is picked",
         %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})

      {:ok, other} =
        Tournaments.create_tournament(scope, %{"name" => "Youth Group", "type" => "swiss"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      assert html =~ "Youth Group"
      # The current tournament is always part of the combined set — it must
      # appear in its own festival's list (checked + disabled), not be
      # silently omitted (user-reported as "doesn't list its own tournament").
      assert html =~ "this tournament, always included"
      assert html =~ "Norms LV"
      assert html =~ "Select at least one tournament above to enable the combined downloads."
      refute html =~ "Download combined IT3"

      html =
        lv
        |> element(~s(input[phx-value-id="#{other.id}"]))
        |> render_click()

      assert html =~ "Download combined IT3"

      assert html =~
               ~s(href="/t/#{tournament.id}/norms/it3?combine=#{tournament.id}%2C#{other.id}&amp;master=#{tournament.id}")

      assert html =~ ~s(action="/t/#{tournament.id}/norms/fa1")
      # Master picker defaults to the current tournament, always part of the set.
      assert html =~ ~s(value="#{tournament.id}" selected)
    end

    test "picking a different master tournament updates the combined IT3 link's master= param", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})

      {:ok, other} =
        Tournaments.create_tournament(scope, %{"name" => "Youth Group", "type" => "swiss"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      lv |> element(~s(input[phx-value-id="#{other.id}"])) |> render_click()

      html =
        lv
        |> form("form[phx-change=set_combine_master]", %{"master" => to_string(other.id)})
        |> render_change()

      assert html =~
               ~s(href="/t/#{tournament.id}/norms/it3?combine=#{tournament.id}%2C#{other.id}&amp;master=#{other.id}")
    end

    test "deselecting the current master falls back to the tournament itself", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})

      {:ok, other} =
        Tournaments.create_tournament(scope, %{"name" => "Youth Group", "type" => "swiss"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      lv |> element(~s(input[phx-value-id="#{other.id}"])) |> render_click()

      lv
      |> form("form[phx-change=set_combine_master]", %{"master" => to_string(other.id)})
      |> render_change()

      # Deselect `other` again — it was the master, so the master resets to
      # the current tournament, and the combined section disappears (no
      # tournaments selected).
      html = lv |> element(~s(input[phx-value-id="#{other.id}"])) |> render_click()

      refute html =~ "Download combined IT3"
      assert html =~ "Select at least one tournament above to enable the combined downloads."
    end
  end
end
