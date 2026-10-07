defmodule PairingsEngineWeb.RatingListSequenceLiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Fide, Meta, RatingLists, Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Sequence Test",
            "type" => "swiss",
            "rounds_count" => "9",
            "round_dates" => List.duplicate(Date.to_iso8601(Date.utc_today()), 9),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL",
            "rate_of_play" => "90 min + 30 sec/move"
          },
          attrs
        )
      )

    tournament
  end

  defp search(lv, query) do
    render_click(lv, "add", %{})
    render_change(lv, "search", %{"q" => query})
  end

  describe "picking a rating from another list (VCL4THP 129)" do
    setup %{scope: scope} do
      Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))

      Repo.insert!(%FidePlayer{
        fide_id: 41,
        name: "Rapidonly, Rita",
        federation: "BEL",
        standard_rating: nil,
        rapid_rating: 1850,
        blitz_rating: 1900
      })

      %{tournament: tournament(scope)}
    end

    test "each other rating is a button of its own", %{conn: conn, tournament: tournament} do
      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/players")
      search(lv, "Rapidonly")

      assert has_element?(lv, "#fide-result-41-other")
      assert has_element?(lv, "#fide-result-41-use-fide_rapid")
      assert has_element?(lv, "#fide-result-41-use-fide_blitz")
    end

    test "picking one fills the rating and records the list it came from", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/players")
      search(lv, "Rapidonly")

      lv |> element("#fide-result-41-use-fide_rapid") |> render_click()
      assert has_element?(lv, "#add-rating-source")
      assert render(lv) =~ "From the FIDE Rapid list of"

      lv |> form("#add-player-form") |> render_submit()

      player = Tournaments.list_players(tournament.id) |> Enum.find(&(&1.fide_id == 41))
      assert player.fide_rating == 1850
      assert player.fide_rating_source == "rapid"
    end

    test "picking the main result leaves the rating empty when the main list has none", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/players")
      search(lv, "Rapidonly")
      lv |> element("#fide-result-41-pick") |> render_click()
      lv |> form("#add-player-form") |> render_submit()

      player = Tournaments.list_players(tournament.id) |> Enum.find(&(&1.fide_id == 41))
      assert player.fide_rating in [nil, 0]
    end

    test "a pick that is not among the offered ones is ignored", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/players")
      search(lv, "Rapidonly")

      html = render_click(lv, "pick_other", %{"fide-id" => "41", "entry" => "fide_standard"})
      refute html =~ "From the FIDE"
      html = render_click(lv, "pick_other", %{"fide-id" => "x", "entry" => "fide_rapid"})
      refute html =~ "From the FIDE"
    end
  end

  describe "the sequence decides the main list (VCL4THP 123, 124, 126)" do
    setup %{scope: scope} do
      Repo.insert!(%FidePlayer{
        fide_id: 42,
        name: "Both, Bea",
        federation: "BEL",
        standard_rating: 1700,
        rapid_rating: 1600,
        blitz_rating: nil
      })

      %{scope: scope}
    end

    test "a rapid tournament's default main list is the effective rapid rating", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, %{"standard" => "rapid"})
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      search(lv, "Both")
      html = lv |> element("#fide-result-42-pick") |> render()
      assert html =~ "1600"
    end

    test "a sequence of the tournament's own puts its first list first", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "rating_list_sequence" => ["fide_rapid", "fide_standard"]
        })

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      search(lv, "Both")
      assert lv |> element("#fide-result-42-pick") |> render() =~ "1600"
      assert has_element?(lv, "#fide-result-42-use-fide_standard")
      refute has_element?(lv, "#fide-result-42-use-fide_blitz")

      lv |> element("#fide-result-42-pick") |> render_click()
      lv |> form("#add-player-form") |> render_submit()
      player = Tournaments.list_players(t.id) |> Enum.find(&(&1.fide_id == 42))
      assert player.fide_rating == 1600
      assert player.fide_rating_source == "rapid"
    end
  end

  describe "custom lists in the add-player search (VCL4THP 117)" do
    test "a hit from a list in the sequence can be picked", %{conn: conn, scope: scope} do
      {:ok, list, _} =
        RatingLists.import_list("Club list", [
          %{
            ext_id: "C7",
            name: "Clubber, Carl",
            rating: 1480,
            federation: "BEL",
            title: "CM",
            birth_year: 1999,
            fide_id: nil
          }
        ])

      t = tournament(scope)

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "rating_list_sequence" => ["fide_standard", "custom:#{list.id}"]
        })

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      search(lv, "Clubber")

      [{_, entry}] = RatingLists.search_custom(["custom:#{list.id}"], "Clubber")
      assert has_element?(lv, "#custom-result-#{entry.id}")
      lv |> element("#custom-result-#{entry.id}") |> render_click()
      lv |> form("#add-player-form") |> render_submit()

      player = Tournaments.list_players(t.id) |> Enum.find(&(&1.name == "Clubber, Carl"))
      assert player.national_rating == 1480
      assert player.title == "CM"
    end

    test "a list that is not in the tournament's sequence is not searched", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _list, _} =
        RatingLists.import_list("Club list", [
          %{
            ext_id: "C7",
            name: "Clubber, Carl",
            rating: 1480,
            federation: "",
            title: "",
            birth_year: nil,
            fide_id: nil
          }
        ])

      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      search(lv, "Clubber")
      refute render(lv) =~ "Clubber, Carl"
    end
  end

  describe "the sequence editor on the FIDE settings page (VCL4THP 124, 126)" do
    test "shows the default, and a change is saved and can be undone", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, %{"standard" => "rapid"})
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/fide")

      assert has_element?(lv, "#rating-sequence-default")
      assert has_element?(lv, "#rating-sequence-0", "Effective Rapid")
      assert has_element?(lv, "#rating-sequence-1", "FIDE Blitz")

      lv |> element("#rating-sequence-down-0") |> render_click()
      assert has_element?(lv, "#rating-sequence-0", "FIDE Blitz")
      refute has_element?(lv, "#rating-sequence-default")

      saved = Tournaments.get_authorized_tournament!(scope, t.id)
      assert saved.rating_list_sequence == ["fide_blitz", "effective_rapid"]

      lv
      |> form("#rating-sequence-add-form", %{"entry" => "national"})
      |> render_submit()

      assert has_element?(lv, "#rating-sequence-2", "National")

      lv |> element("#rating-sequence-remove-0") |> render_click()
      saved = Tournaments.get_authorized_tournament!(scope, t.id)
      assert saved.rating_list_sequence == ["effective_rapid", "national"]

      lv |> element("#rating-sequence-reset") |> render_click()
      saved = Tournaments.get_authorized_tournament!(scope, t.id)
      assert saved.rating_list_sequence == nil
      assert has_element?(lv, "#rating-sequence-default")
    end

    test "the last list cannot be removed", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, t} = Tournaments.update_tournament(t, %{"rating_list_sequence" => ["fide_rapid"]})
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/fide")

      assert has_element?(lv, "#rating-sequence-remove-0[disabled]")
      render_click(lv, "seq_remove", %{"index" => "0"})
      saved = Tournaments.get_authorized_tournament!(scope, t.id)
      assert saved.rating_list_sequence == ["fide_rapid"]
    end

    test "a custom list can be added", %{conn: conn, scope: scope} do
      {:ok, list, _} =
        RatingLists.import_list("Club list", [
          %{
            ext_id: "1",
            name: "A",
            rating: 1000,
            federation: "",
            title: "",
            birth_year: nil,
            fide_id: nil
          }
        ])

      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/fide")

      lv
      |> form("#rating-sequence-add-form", %{"entry" => "custom:#{list.id}"})
      |> render_submit()

      assert has_element?(lv, "#rating-sequence-3", "Club list")
    end
  end

  describe "switching consistency checks off (VCL4THP 138)" do
    setup %{scope: scope} do
      Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))
      t = tournament(scope)

      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Alice",
          "fide_id" => "1",
          "fide_rating" => "1000"
        })

      Repo.insert!(%FidePlayer{fide_id: 1, name: "Alice", standard_rating: 1100})
      %{tournament: t}
    end

    test "the notice is shown by default and gone once the checks are off", %{
      conn: conn,
      tournament: t
    } do
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      assert has_element?(lv, "#rating-check-notice")

      {:ok, settings, _} = live(conn, ~p"/t/#{t.id}/settings/fide")
      assert has_element?(settings, "#rating-checks-enabled[checked]")

      settings
      |> element("#rating-checks-form")
      |> render_change(%{"enabled" => "false"})

      refute Tournaments.get_tournament!(t.id).rating_checks_enabled

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      refute has_element?(lv, "#rating-check-notice")
      # Asking for the check by hand still works.
      lv |> element("button", "Refresh ratings") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#rating-refresh-dialog")
    end
  end

  describe "the Rating lists page (VCL4THP 117)" do
    setup %{conn: conn, user: user} do
      {:ok, admin} = Accounts.set_role(user.email, "admin")
      %{conn: log_in_user(conn, admin)}
    end

    defp upload(lv, content, name \\ "list.csv") do
      lv
      |> file_input("#custom-list-form", :csv, [
        %{name: name, content: content, type: "text/csv"}
      ])
      |> render_upload(name)
    end

    test "a valid file is previewed, then loaded", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/rating-lists")
      assert has_element?(lv, "#no-custom-lists")

      upload(lv, "id,name,rating\n1,Smith,1500\n2,Jones,\n")
      lv |> form("#custom-list-form", %{"name" => "Club"}) |> render_submit()

      assert has_element?(lv, "#custom-list-sample")
      refute has_element?(lv, "#custom-list-replaces")
      assert RatingLists.custom_lists() == []

      lv |> element("#custom-list-confirm") |> render_click()
      assert has_element?(lv, "#rating-list-notice")
      assert [%{name: "Club", entry_count: 2}] = RatingLists.custom_lists()
      refute has_element?(lv, "#no-custom-lists")
    end

    test "a file with a bad row is refused with the line", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/rating-lists")
      upload(lv, "id,name,rating\n1,Smith,1500\n2,Jones,lots\n")
      lv |> form("#custom-list-form", %{"name" => "Club"}) |> render_submit()

      assert has_element?(lv, "#custom-list-errors", "Line 3")
      refute has_element?(lv, "#custom-list-confirm")
      assert RatingLists.custom_lists() == []
    end

    test "loading again under the same name says it replaces the list", %{conn: conn} do
      {:ok, _, _} =
        RatingLists.import_list("Club", [
          %{
            ext_id: "1",
            name: "Old",
            rating: 1000,
            federation: "",
            title: "",
            birth_year: nil,
            fide_id: nil
          }
        ])

      {:ok, lv, _} = live(conn, ~p"/rating-lists")
      upload(lv, "id,name,rating\n9,New,1200\n")
      lv |> form("#custom-list-form", %{"name" => "club"}) |> render_submit()
      assert has_element?(lv, "#custom-list-replaces")
    end

    test "a list can be deleted", %{conn: conn} do
      {:ok, list, _} =
        RatingLists.import_list("Club", [
          %{
            ext_id: "1",
            name: "Old",
            rating: 1000,
            federation: "",
            title: "",
            birth_year: nil,
            fide_id: nil
          }
        ])

      {:ok, lv, _} = live(conn, ~p"/rating-lists")
      lv |> element("#delete-custom-list-#{list.id}") |> render_click()
      assert RatingLists.custom_lists() == []
    end

    test "an account that is not an administrator cannot load a list", %{conn: conn} do
      user = PairingsEngine.AccountsFixtures.user_fixture()
      {:ok, support} = Accounts.set_role(user.email, "support")
      {:ok, lv, _} = live(log_in_user(conn, support), ~p"/rating-lists")

      html = render_submit(lv, "preview", %{"name" => "Club"})
      assert html =~ "needs an administrator"
      assert render_click(lv, "confirm_import", %{}) =~ "needs an administrator"
      assert RatingLists.custom_lists() == []
    end
  end
end
