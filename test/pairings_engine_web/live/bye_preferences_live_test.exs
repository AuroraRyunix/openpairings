defmodule PairingsEngineWeb.ByePreferencesLiveTest do
  @moduledoc """
  Bye preferences on the pages: the player form (not behind any pack's
  switch, never on a FIDE-rated tournament), the marker in the player list,
  the Pairings page's notice, the round's explanation, the Export page's
  note and the audit trail. Ainalrami only, so no JVM.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, Tournaments}

  setup [:register_and_log_in_user, :enable_federation_features]

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Bye preferences",
            "type" => "swiss",
            "pairing_engine" => "ainalrami",
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

  defp player(t, name, attrs \\ %{}) do
    {:ok, p} = Tournaments.create_player(t.id, Map.merge(%{"name" => name}, attrs))
    p
  end

  defp open_edit(conn, t, p) do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    render_click(lv, "edit_player", %{"id" => to_string(p.id)})
    lv
  end

  defp five(t, attrs_for_first) do
    for {{name, rating}, i} <-
          Enum.with_index([{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}, {"E", 1600}]) do
      player(
        t,
        name,
        Map.merge(%{"fide_rating" => "#{rating}"}, if(i == 0, do: attrs_for_first, else: %{}))
      )
    end
  end

  describe "the player form" do
    test "a choice, then all or certain rounds, and the warning every time", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      p = player(t, "Anna")
      lv = open_edit(conn, t, p)

      assert has_element?(lv, "#player-bye-preference-select")
      refute has_element?(lv, "#player-bye-preference-scope")
      refute has_element?(lv, "#player-bye-preference-warning")

      lv
      |> form("#player-edit-form", %{"player" => %{"bye_preference" => "want_hard"}})
      |> render_change()

      assert has_element?(lv, "#player-bye-preference-scope-all[checked]")
      assert has_element?(lv, "#player-bye-preference-warning")
      assert has_element?(lv, "#player-bye-preference-meaning", "Must get it")

      lv
      |> form("#player-edit-form", %{
        "player" => %{"bye_preference" => "want_hard", "bye_preference_scope" => "rounds"}
      })
      |> render_change()

      assert has_element?(lv, "#player-bye-preference-rounds")

      lv
      |> form("#player-edit-form", %{
        "player" => %{
          "bye_preference" => "want_hard",
          "bye_preference_scope" => "rounds",
          "bye_preference_rounds" => "4-2"
        }
      })
      |> render_submit()

      p = Repo.reload!(p)
      assert p.bye_preference == "want_hard"
      assert p.bye_preference_rounds == "2,3,4"
      assert has_element?(lv, "#player-bye-preference-marker-#{p.id}", "bye: must")

      row = t.id |> Audit.list_for_tournament(action: "player.updated") |> List.first()
      assert Map.has_key?(row.details["changed_fields"], "bye_preference")
    end

    test "wanting the bye while excluded from it is refused with a reason", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      p = player(t, "Anna", %{"no_bye" => "true", "no_bye_scope" => "all"})
      lv = open_edit(conn, t, p)

      html =
        lv
        |> form("#player-edit-form", %{"player" => %{"bye_preference" => "want_soft"}})
        |> render_submit()

      assert html =~ "cannot want the pairing-allocated bye while excluded from it"
      assert Repo.reload!(p).bye_preference == ""
    end

    test "a FIDE-rated tournament says why it is not offered, and shows a stored one as ignored",
         %{
           conn: conn,
           scope: scope
         } do
      t = tournament(scope, %{"fide_homologated" => "true"})
      plain = player(t, "Anna")
      lv = open_edit(conn, t, plain)
      refute has_element?(lv, "#player-bye-preference-select")
      # Switch on, so the note says why there is no control, never silence.
      assert has_element?(lv, "#player-bye-preference-ignored", "FIDE-rated")

      t = tournament(scope)
      stored = player(t, "Bert", %{"bye_preference" => "want_hard"})
      {:ok, t} = Tournaments.update_tournament(t, %{"fide_homologated" => "true"})

      lv = open_edit(conn, t, stored)
      refute has_element?(lv, "#player-bye-preference-select")
      assert has_element?(lv, "#player-bye-preference-ignored")
      assert has_element?(lv, "#player-bye-preference-marker-#{stored.id}.pe-tag-muted")
      assert Repo.reload!(stored).bye_preference == "want_hard"
    end

    test "JaVaFo: no control, a one-line reason; a stored one names its value", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, %{"pairing_engine" => "javafo"})
      p = player(t, "Anna")
      lv = open_edit(conn, t, p)
      refute has_element?(lv, "#player-bye-preference-select")
      assert has_element?(lv, "#player-bye-preference-javafo", "not available")

      q = player(t, "Bert", %{"bye_preference" => "want_soft"})
      lv = open_edit(conn, t, q)
      assert has_element?(lv, "#player-bye-preference-javafo")
    end

    test "round robin and Keizer: not there at all", %{conn: conn, scope: scope} do
      for system <- ~w(round_robin keizer) do
        t = tournament(scope, %{"pairing_system" => system})
        p = player(t, "Anna", %{"bye_preference" => "want_hard"})
        lv = open_edit(conn, t, p)

        refute has_element?(lv, "#player-bye-preference")
        refute has_element?(lv, "#player-bye-preference-marker-#{p.id}")
      end
    end
  end

  describe "its own switch" do
    test "off: not offered; a stored preference stays visible", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      {:ok, _} = PairingsEngine.Features.set_enabled(user, [])

      t = tournament(scope)
      p = player(t, "Anna")
      lv = open_edit(conn, t, p)
      refute has_element?(lv, "#player-bye-preference-select")
      # One switch for both since 0.74.2: the exclusion is off with it.
      refute has_element?(lv, "#player-no-bye-toggle")

      stored = player(t, "Cleo", %{"bye_preference" => "avoid_soft"})
      lv = open_edit(conn, t, stored)
      assert has_element?(lv, "#player-bye-preference-select")
      assert has_element?(lv, "#player-bye-preference-marker-#{stored.id}")
    end

    test "is a switch on the account's features page, in the Belgian pack", %{
      conn: conn,
      user: user
    } do
      {:ok, _} = PairingsEngine.Features.set_enabled(user, [])
      {:ok, lv, _html} = live(conn, ~p"/users/features")
      assert has_element?(lv, "#features-form", "Bye preferences")

      lv
      |> form("#features-form", %{"feature" => %{"bye_preferences" => "true"}})
      |> render_change()

      assert PairingsEngine.Accounts.get_user!(user.id).features == ["bye_preferences"]
    end
  end

  describe "a second pairing-allocated bye" do
    test "the Pairings page refuses the round and names the player and the round of their bye",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      [_a, _b, _c, _d, e] = five(t, %{})

      {:ok, _} =
        Tournaments.update_player(e, %{
          "bye_preference" => "want_hard",
          "bye_preference_scope" => "all"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "pair", %{})
      render(lv)
      [r1] = Tournaments.list_rounds(t.id)

      for p <- Repo.preload(r1, :pairings).pairings, p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = render_click(lv, "pair", %{})

      assert html =~
               "Round 2 was not paired: E must get the pairing-allocated bye, but already had it in round 1"

      assert length(Tournaments.list_rounds(t.id)) == 1
    end
  end

  describe "a preference that moved the bye" do
    test "is said on the Pairings page, explained on the round, noted on Export and in the trail",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      [first | _] = five(t, %{"bye_preference" => "want_hard"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "pair", %{})
      render(lv)

      assert [_round] = Tournaments.list_rounds(t.id)
      assert has_element?(lv, "#bye-preference-notice", "went to A")

      row = t.id |> Audit.list_for_tournament(action: "pairing.bye_preference") |> List.first()
      assert row.details["moved"] == true
      assert row.details["player_id"] == first.id

      lost =
        t.id
        |> Audit.list_for_tournament(action: "tournament.fide_compliance_lost")
        |> List.first()

      assert lost.details["setting"] == "bye_preference"
      assert lost.details["round"] == 1

      {:ok, explain, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
      assert has_element?(explain, "#bye-preference-account", "went to A")

      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(export, "#trf-bye-preference-note")
    end

    test "a hard want no legal pairing allows is paired normally, and the page says why", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [a, b, c, d, e] = five(t, %{"bye_preference" => "want_hard"})
      for other <- [c, d, e], do: {:ok, _} = Tournaments.add_forbidden_pairing(t, b.id, other.id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "pair", %{})
      render(lv)

      assert [_round] = Tournaments.list_rounds(t.id)
      assert has_element?(lv, "#bye-preference-notice", "no legal pairing gives it to them")
      refute Repo.reload!(t).fide_compliance_lost_round
      assert a.bye_preference == "want_hard"
    end
  end

  describe "a FIDE-rated tournament" do
    test "the Pairings page names the preferences it is ignoring", %{conn: conn, scope: scope} do
      t = tournament(scope)
      five(t, %{"bye_preference" => "avoid_soft"})
      {:ok, _t} = Tournaments.update_tournament(t, %{"fide_homologated" => "true"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(lv, "#bye-preference-ignored", "A has a bye preference")

      render_click(lv, "pair", %{})
      render(lv)
      [round] = Tournaments.list_rounds(t.id)
      explanation = Tournaments.get_round_explanation(t.id, round.number)
      refute Enum.any?(explanation["sections"], &Map.has_key?(&1, "bye_preference"))
      refute has_element?(lv, "#bye-preference-notice")
    end

    test "ticking FIDE-homologated warns about the preferences it will ignore", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      five(t, %{"bye_preference" => "want_soft"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/fide")
      refute has_element?(lv, "#fide-bye-preference-ignored")

      lv
      |> form("#fide-settings-form", %{"tournament" => %{"fide_homologated" => "true"}})
      |> render_submit()

      assert Repo.reload!(t).fide_homologated
      assert has_element?(lv, "#fide-bye-preference-ignored", "A has a bye preference")
    end
  end
end
