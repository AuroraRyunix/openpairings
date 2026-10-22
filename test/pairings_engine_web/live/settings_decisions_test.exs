defmodule PairingsEngineWeb.SettingsDecisionsTest do
  @moduledoc """
  The Settings decisions of the 2026-10-22 UX audit: the format locked once
  round 1 is paired, the re-scoring warning on the points, round dates in
  order, typed (unverified) FIDE IDs for officials, the organizer owned by
  Settings > Tournament, the leave-with-unsaved-edits guard, and the
  refusal sentences in the reader's language.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Round

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Decisions", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    t
  end

  defp pair_round_one(t),
    do: Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "playing"})

  describe "the format after round 1" do
    test "is open before round 1 is paired", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")

      assert has_element?(lv, "#tournament-type")
      refute has_element?(lv, "#tournament-type[disabled]")
      refute has_element?(lv, "#type-locked-note")
    end

    test "is disabled with a sentence why, and the server refuses a change",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      pair_round_one(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")
      assert has_element?(lv, "#tournament-type[disabled]")
      assert has_element?(lv, "#type-locked-note")

      assert {:error, changeset} = Tournaments.update_tournament(t, %{"type" => "roundrobin"})
      assert {_, opts} = changeset.errors[:type]
      assert opts[:validation] == :type_after_pairing
      assert Tournaments.get_tournament!(t.id).type == "swiss"

      # The same type again is no change.
      assert {:ok, _} = Tournaments.update_tournament(t, %{"type" => "swiss"})
    end
  end

  describe "the points after round 1" do
    test "a changed win value warns once rounds exist, and still saves",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/scoring")

      lv
      |> form("#scoring-settings-form", %{"tournament" => %{"points_win" => "3"}})
      |> render_change()

      refute has_element?(lv, "#points-change-warning")

      pair_round_one(t)
      # FIDE mode locks the points outright once rounds exist; the warning is
      # for the tournament that is free to change them.
      {:ok, _} = Tournaments.leave_fide_mode(Tournaments.get_tournament!(t.id))
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/scoring")

      lv
      |> form("#scoring-settings-form", %{"tournament" => %{"points_win" => "3"}})
      |> render_change()

      assert has_element?(lv, "#points-change-warning")

      lv
      |> form("#scoring-settings-form", %{"tournament" => %{"points_win" => "3"}})
      |> render_submit()

      assert Tournaments.get_tournament!(t.id).points_win == 3.0
      refute has_element?(lv, "#points-change-warning")
    end
  end

  describe "round dates" do
    test "out of order are refused; a shared date is fine", %{conn: conn, scope: scope} do
      t = tournament(scope, %{"rounds_count" => "3"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/dates")

      lv
      |> form("#round-dates-form", %{
        "tournament" => %{"round_dates" => ["2026-07-15", "2026-07-14", ""]}
      })
      |> render_submit()

      assert has_element?(lv, "#round-dates-form .tset-error")
      assert Tournaments.get_tournament!(t.id).round_dates in [[], ["", "", ""]]

      lv
      |> form("#round-dates-form", %{
        "tournament" => %{"round_dates" => ["2026-07-14", "2026-07-14", "2026-07-15"]}
      })
      |> render_submit()

      refute has_element?(lv, "#round-dates-form .tset-error")

      assert Tournaments.get_tournament!(t.id).round_dates ==
               ["2026-07-14", "2026-07-14", "2026-07-15"]
    end

    test "the refusal is translated", %{scope: scope} do
      t = tournament(scope, %{"rounds_count" => "2"})

      {:error, changeset} =
        Tournaments.update_tournament(t, %{"round_dates" => ["2026-07-15", "2026-07-14"]},
          round_dates_order: :refuse
        )

      text =
        Gettext.with_locale(PairingsEngineWeb.Gettext, "nl", fn ->
          PairingsEngineWeb.SettingsSupport.error_text(changeset)
        end)

      assert text =~ "ronde 2"
      assert text =~ "Niet bewaard"
    end
  end

  describe "officials without a FIDE list" do
    test "a typed FIDE ID is taken, flagged unverified, and saves",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/norms")

      lv
      |> element("#arbiter-combo-chief_arbiter-id-search")
      |> render_change(%{
        "fide_id_search" => %{"chief_arbiter_fide_id" => "20512345"},
        "_target" => ["fide_id_search", "chief_arbiter_fide_id"]
      })

      assert has_element?(lv, "#arbiter-combo-chief_arbiter-id-results-empty")
      lv |> element("#arbiter-combo-chief_arbiter-use-typed") |> render_click()
      assert has_element?(lv, "#arbiter-combo-chief_arbiter-unverified")

      lv
      |> form("#officials-form", %{"tournament" => %{"chief_arbiter" => "Typed, Arbiter"}})
      |> render_submit()

      saved = Tournaments.get_tournament!(t.id)
      assert saved.chief_arbiter == "Typed, Arbiter"
      assert saved.officials["chief_arbiter_fide_id"] == "20512345"
      assert saved.officials["chief_arbiter_fide_id_unverified"] == "true"

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/norms")
      assert has_element?(lv, "#arbiter-combo-chief_arbiter-unverified")
    end

    test "text that is not a FIDE ID is not offered", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/norms")

      lv
      |> element("#arbiter-combo-chief_arbiter-id-search")
      |> render_change(%{
        "fide_id_search" => %{"chief_arbiter_fide_id" => "12ab"},
        "_target" => ["fide_id_search", "chief_arbiter_fide_id"]
      })

      refute has_element?(lv, "#arbiter-combo-chief_arbiter-use-typed")
    end
  end

  describe "the organizer" do
    setup do
      Repo.insert!(%PairingsEngine.Fide.FidePlayer{
        fide_id: 300_100,
        name: "Burssens, Jorian",
        federation: "BEL"
      })

      :ok
    end

    defp pick_organizer(lv) do
      lv
      |> element("#arbiter-combo-organizer-name")
      |> render_change(%{
        "tournament" => %{"organizer" => "Burssens"},
        "_target" => ["tournament", "organizer"]
      })

      lv
      |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="300100"]))
      |> render_click()
    end

    test "is picked with its FIDE ID on Settings > Tournament", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")

      pick_organizer(lv)
      lv |> form("#tournament-settings-form") |> render_submit()

      saved = Tournaments.get_tournament!(t.id)
      assert saved.organizer == "Burssens, Jorian"
      assert saved.officials["organizer_id"] == "300100"
    end

    test "a new name without a new pick clears the stale id, and the page says so",
         %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "organizer" => "Burssens, Jorian",
          "officials" => %{"organizer_id" => "300100", "organizer_email" => "o@example.com"}
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")
      refute has_element?(lv, "#organizer-id-stale-note")

      lv
      |> element("#arbiter-combo-organizer-name")
      |> render_change(%{
        "tournament" => %{"organizer" => "KSK Somewhere"},
        "_target" => ["tournament", "organizer"]
      })

      assert has_element?(lv, "#organizer-id-stale-note")

      lv
      |> form("#tournament-settings-form", %{"tournament" => %{"organizer" => "KSK Somewhere"}})
      |> render_submit()

      saved = Tournaments.get_tournament!(t.id)
      assert saved.organizer == "KSK Somewhere"
      refute Map.has_key?(saved.officials, "organizer_id")
      # The rest of `officials` is not this page's to drop.
      assert saved.officials["organizer_email"] == "o@example.com"
      assert has_element?(lv, "#organizer-id-cleared-note")
      refute has_element?(lv, "#organizer-id-stale-note")
    end

    test "Officials shows it read-only with a link, and its save keeps the id",
         %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "organizer" => "Burssens, Jorian",
          "officials" => %{"organizer_id" => "300100"}
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/norms")

      assert has_element?(lv, "#officials-organizer-name", "Burssens, Jorian")
      assert has_element?(lv, "#officials-organizer-id", "300100")
      assert has_element?(lv, ~s(#officials-organizer-edit[href="/t/#{t.id}/settings"]))
      refute has_element?(lv, "input[name='tournament[organizer]']")

      lv
      |> form("#officials-form", %{"tournament" => %{"officials" => %{"it4_event_type" => "x"}}})
      |> render_submit()

      saved = Tournaments.get_tournament!(t.id)
      assert saved.organizer == "Burssens, Jorian"
      assert saved.officials["organizer_id"] == "300100"
    end
  end

  describe "leaving with unsaved edits" do
    test "the settings forms carry the guard; save-as-you-go forms opt out",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, _} = Tournaments.add_collaborator(scope, t, "helper@example.com")
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")

      assert has_element?(lv, "#settings-page[phx-hook][data-unsaved-message]")
      assert has_element?(lv, "form[id^=collaborator-role-form-][data-unsaved-ignore]")

      for page <- ~w(dates scoring options rooms norms fide) do
        {:ok, lv, _html} = live(conn, "/t/#{t.id}/settings/#{page}")
        assert has_element?(lv, "#settings-page[data-unsaved-message]"), page
      end

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/about")
      refute has_element?(lv, "#settings-page[data-unsaved-message]")
    end
  end

  describe "refusal sentences" do
    test "arrive in the reader's language" do
      nl =
        Gettext.with_locale(PairingsEngineWeb.Gettext, "nl", fn ->
          {Tournaments.refusal_message(:archived, "pairing"),
           Tournaments.refusal_message(:handed_off, "unpairing")}
        end)

      assert nl ==
               {"Dit toernooi is gearchiveerd - haal het uit het archief voordat je paart.",
                "Dit toernooi is overgedragen - neem het terug voordat je de paring ongedaan maakt."}

      assert Tournaments.refusal_message(:archived, "pairing") ==
               "This tournament is archived - unarchive it before pairing."
    end
  end
end
