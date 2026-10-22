defmodule PairingsEngineWeb.DecisionsDataTest do
  @moduledoc """
  The UX-gap decisions about data: local times, the tournaments card list,
  badge autosave tick, renames, warn-only player data, the stored "last
  checked", incident handling and the publishing pill's raw reason.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Audit, Badges, Incidents, RatingLists, Registrations}
  alias PairingsEngine.{Repo, Snapshots, Tournaments}
  alias PairingsEngine.Incidents.Incident
  alias PairingsEngine.PlayerWarnings
  alias PairingsEngineWeb.Components.ConnectionStatus
  alias PairingsEngineWeb.Components.LocalTime

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Decisions Open", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    t
  end

  describe "local time (2)" do
    test "renders a <time> with the UTC instant, a UTC tooltip and the hook" do
      html =
        render_component(&LocalTime.local_time/1,
          id: "t1",
          at: ~U[2026-10-22 14:05:00Z],
          format: "datetime"
        )

      doc = LazyHTML.from_fragment(html)
      time = LazyHTML.query(doc, "time#t1")
      assert LazyHTML.attribute(time, "datetime") == ["2026-10-22T14:05:00Z"]
      assert LazyHTML.attribute(time, "title") == ["2026-10-22 14:05 UTC"]
      assert LazyHTML.attribute(time, "phx-hook") != []
    end

    test "the audit page uses it", %{conn: conn, scope: scope} do
      t = tournament(scope)
      Audit.log(t.id, scope, "category.created", %{name: "U12"})
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/audit")
      assert has_element?(lv, "td time[id^=audit-at-]")
    end
  end

  describe "tournaments list as cards (4)" do
    test "each row carries the card classes", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/")
      assert has_element?(lv, "#tournament-row-#{t.id}.tour-row")
      assert has_element?(lv, "#tournament-row-#{t.id} td.tour-cell-status")
      assert has_element?(lv, "#tournament-row-#{t.id} td.tour-cell-actions")
    end
  end

  describe "badge autosave tick (5)" do
    test "shows a tick and the hint after a save", %{conn: conn, scope: scope} do
      {:ok, event} = Badges.create_event(scope, %{name: "Press Day"})
      {:ok, badge} = Badges.create_badge(scope, event)
      {:ok, lv, _} = live(conn, ~p"/badges/#{event.id}/badge/#{badge.id}")

      assert has_element?(lv, "#badge-autosave-hint")
      refute has_element?(lv, ".badge-saved-tick")

      lv |> form("#badge-form", badge: %{first_name: "Maggie"}) |> render_change()
      assert has_element?(lv, ".badge-saved-tick")
    end
  end

  describe "rating list rename (7)" do
    defp entry,
      do: %{
        ext_id: "1",
        name: "A",
        rating: 1000,
        federation: "",
        title: "",
        birth_year: nil,
        fide_id: nil
      }

    test "keeps the id, so sequence references hold", %{conn: conn, user: user} do
      {:ok, admin} = Accounts.set_role(user.email, "admin")
      conn = log_in_user(conn, admin)
      {:ok, list, _} = RatingLists.import_list("Club", [entry()])

      {:ok, lv, _} = live(conn, ~p"/rating-lists")
      lv |> element("#rename-custom-list-#{list.id}") |> render_click()

      lv
      |> form("#rename-custom-list-form-#{list.id}", rename: %{name: "Club 2026"})
      |> render_submit()

      assert has_element?(lv, "#rating-list-notice")
      assert [%{id: id, name: "Club 2026"}] = RatingLists.custom_lists()
      assert id == list.id
      assert RatingLists.valid_entry?("custom:#{list.id}")
    end

    test "refuses a name another list has" do
      {:ok, a, _} = RatingLists.import_list("One", [entry()])
      {:ok, _b, _} = RatingLists.import_list("Two", [entry()])
      assert {:error, :taken} = RatingLists.rename_list(a.id, "two")
      assert {:error, :blank} = RatingLists.rename_list(a.id, "  ")
      assert {:ok, _, "One"} = RatingLists.rename_list(a.id, "ONE")
    end
  end

  describe "category rename (7)" do
    test "rewrites the list, rules, prizes and players, after a restore point", %{
      conn: conn,
      scope: scope
    } do
      t =
        tournament(scope, %{
          "categories_enabled" => true,
          "categories" => ["U12", "U16"],
          "category_rules" => %{"U12" => %{"age_below" => 12}},
          "category_prizes" => %{"U12" => 3}
        })

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Kid",
          "categories" => ["U12"],
          "category" => "U12"
        })

      before_count = Snapshots.count(t.id)

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/categories")
      lv |> element("#rename-category-0") |> render_click()
      lv |> form("#rename-category-form", rename: %{name: "Under 12"}) |> render_submit()

      t = Tournaments.get_tournament!(t.id)
      assert t.categories == ["Under 12", "U16"]
      assert t.category_rules == %{"Under 12" => %{"age_below" => 12}}
      assert t.category_prizes == %{"Under 12" => 3}

      p = Tournaments.get_player(t.id, p.id)
      assert p.categories == ["Under 12"]
      assert p.category == "Under 12"

      assert Snapshots.count(t.id) > before_count
      assert Enum.any?(Snapshots.list(t.id), &(&1.trigger == "category.renamed"))
    end

    test "refuses a name that exists", %{conn: conn, scope: scope} do
      t = tournament(scope, %{"categories_enabled" => true, "categories" => ["A", "B"]})
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/categories")
      lv |> element("#rename-category-0") |> render_click()
      lv |> form("#rename-category-form", rename: %{name: "B"}) |> render_submit()
      assert has_element?(lv, "#rename-category-error")
      assert Tournaments.get_tournament!(t.id).categories == ["A", "B"]
    end
  end

  describe "warn-only player data (8)" do
    test "flags the odd values and nothing else" do
      assert PlayerWarnings.check(%{"fide_rating" => "3400"}) == [:rating]
      assert PlayerWarnings.check(%{"national_rating" => "-5"}) == [:rating]
      assert PlayerWarnings.check(%{"birth_year" => "1850"}) == [:birth_year]
      assert PlayerWarnings.check(%{"federation" => "Belgium"}) == [:federation]

      assert PlayerWarnings.check(%{
               "fide_rating" => "1800",
               "birth_year" => "2010",
               "federation" => "BEL"
             }) == []

      assert PlayerWarnings.check(%{"fide_rating" => "", "birth_year" => "", "federation" => ""}) ==
               []
    end

    test "the player is still saved, and the Players page says so", %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Odd",
          "fide_rating" => 4000,
          "birth_year" => 1800,
          "federation" => "Belgium"
        })

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      assert has_element?(lv, "#players-data-warnings")
    end
  end

  describe "entries last checked (9)" do
    defp set_checked(t) do
      Repo.update_all(from(x in Tournaments.Tournament, where: x.id == ^t.id),
        set: [registrations_checked_at: ~U[2026-10-22 10:00:00Z]]
      )
    end

    test "is stored per tournament and read back", %{scope: scope} do
      t = tournament(scope)
      assert Registrations.last_checked(t.id) == nil
      set_checked(t)
      assert Registrations.last_checked(t.id) == ~U[2026-10-22 10:00:00Z]
    end

    test "the page shows it on a fresh visit", %{conn: conn, scope: scope} do
      PairingsEngine.Publishing.put_endpoint("https://openresults.example/")
      PairingsEngine.Publishing.put_token("s3cret")
      t = tournament(scope)
      {:ok, t} = Tournaments.set_publish_to_openresults(t, true)
      set_checked(t)

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/registrations")
      assert has_element?(lv, "#registrations-last-checked-at")
    end
  end

  describe "incidents handled and removed (10)" do
    defp incident(t) do
      Repo.insert!(%Incident{
        tournament_id: t.id,
        round_number: 1,
        board: 3,
        kind: "arbiter_call",
        note: "Flag",
        occurred_at: ~U[2026-10-22 10:00:00Z]
      })
    end

    defp actions(t), do: t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)

    test "handled toggles the highlight and is audited", %{conn: conn, scope: scope} do
      t = tournament(scope)
      i = incident(t)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/incidents")
      assert has_element?(lv, "#incident-#{i.id}.incident-call")

      lv |> element("#incident-handled-#{i.id}") |> render_click()
      assert has_element?(lv, "#incident-#{i.id}.incident-handled")
      refute has_element?(lv, "#incident-#{i.id}.incident-call")
      assert Repo.reload!(i).handled_at

      lv |> element("#incident-handled-#{i.id}") |> render_click()
      assert has_element?(lv, "#incident-#{i.id}.incident-call")
      assert is_nil(Repo.reload!(i).handled_at)

      assert "incident.handled" in actions(t) and "incident.reopened" in actions(t)
    end

    test "remove carries a confirm, deletes and audits", %{conn: conn, scope: scope} do
      t = tournament(scope)
      i = incident(t)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/incidents")
      assert has_element?(lv, "#incident-delete-#{i.id}[data-confirm]")

      lv |> element("#incident-delete-#{i.id}") |> render_click()
      refute has_element?(lv, "#incident-#{i.id}")
      assert Repo.get(Incident, i.id) == nil
      assert Incidents.list(t.id) == []
      assert "incident.deleted" in actions(t)
    end
  end

  describe "publishing pill raw reason (21)" do
    test "an unknown error gets a plain sentence and a disclosure" do
      status = %{
        latency_ms: nil,
        last_published_at: nil,
        last_publish_bytes: nil,
        state: :unreachable,
        mode: :public,
        endpoint: "https://openresults.example",
        pending: 0,
        reason: {:unreachable, {:weird, :thing}},
        checked_at: nil,
        last_ok_at: nil
      }

      html = render_component(&ConnectionStatus.connection_status/1, status: status)
      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("details#conn-raw-reason summary") |> Enum.count() == 1
      assert LazyHTML.text(LazyHTML.query(doc, "details#conn-raw-reason code")) =~ "weird"
    end

    test "a known error has no disclosure" do
      assert ConnectionStatus.raw_term({:unreachable, :timeout}) == nil
      assert ConnectionStatus.raw_term({:unreachable, {:weird, :thing}}) =~ "weird"
    end
  end
end
