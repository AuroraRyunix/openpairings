defmodule PairingsEngineWeb.RegistrationQueueLiveTest do
  @moduledoc """
  The entries from the results site's form where the arbiter already is: a
  queue on the Players page (`PairingsEngineWeb.RegistrationQueue`), and the
  form's window and cap on Settings > Results site.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Features, Publishing, Registrations, Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Federations.BEL.Member
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngine.Tournaments.Tournament

  @email "lotte.janssens@example.invalid"

  setup :register_and_log_in_user

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp tournament(scope, opts \\ []) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Brugse Open",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    {:ok, t} = Tournaments.set_publish_to_openresults(t, true)
    {:ok, t} = Tournaments.set_registration_open(t, Keyword.get(opts, :open, true))
    t
  end

  # An entry as a pull stores it - the pull itself is covered by the context
  # tests; these are about the screen.
  defp pending!(tournament, player, n \\ 1) do
    Repo.insert!(%Registration{
      tournament_id: tournament.id,
      external_key: "id:#{n}",
      received_at: DateTime.utc_now(),
      payload: %{"schema" => "openresults/registration", "version" => 1, "player" => player},
      status: "pending"
    })
  end

  defp lotte(overrides \\ %{}) do
    Map.merge(%{"name" => "Janssens, Lotte", "email" => @email, "rating" => 1900}, overrides)
  end

  describe "the Players page" do
    test "shows each waiting entry with its email, and Accept makes the player", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      registration = pending!(t, lotte())

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      assert has_element?(lv, "#registration-queue-card")
      assert has_element?(lv, "#registration-#{registration.id}", "Janssens, Lotte")
      # Behind the login, and the reason the field exists.
      assert has_element?(lv, "#registration-#{registration.id}", @email)

      lv |> element("#accept-registration-#{registration.id}") |> render_click()

      assert [player] = Tournaments.list_players(t.id)
      assert player.name == "Janssens, Lotte"
      assert player.absent
      refute has_element?(lv, "#registration-#{registration.id}")
      assert render(lv) =~ "Added Janssens, Lotte"
    end

    test "Discard creates nothing", %{conn: conn, scope: scope} do
      t = tournament(scope)
      registration = pending!(t, lotte())

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      lv |> element("#discard-registration-#{registration.id}") |> render_click()

      assert Tournaments.list_players(t.id) == []
      assert Registrations.pending(t.id) == []
      assert render(lv) =~ "No player was created"
    end

    test "flags a probable duplicate before anybody presses Accept", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Janssens, Lotte"})
      registration = pending!(t, lotte(%{"name" => "lotte janssens"}))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      assert has_element?(lv, "#duplicates-#{registration.id} .reg-duplicate-name")
    end

    test "shows the player the entry becomes, prefilled from the lists", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _user} = Features.set_enabled(scope.user, ["bel_player_lookup"])

      Repo.insert!(%FidePlayer{
        fide_id: 210_999,
        name: "Janssens, Lotte",
        federation: "BEL",
        standard_rating: 1987
      })

      Repo.insert!(%Member{
        national_id: "4711",
        last_name: "Janssens",
        first_name: "Lotte",
        fide_id: 210_999,
        club_name: "KBSK Brugge",
        national_rating: 1950
      })

      t = tournament(scope)
      registration = pending!(t, lotte(%{"national_id" => "4711"}))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      html = lv |> element("#registration-#{registration.id}") |> render()

      assert html =~ "1987"
      assert html =~ "KBSK Brugge"
      assert html =~ "national ID 4711"

      lv |> element("#accept-registration-#{registration.id}") |> render_click()
      [player] = Tournaments.list_players(t.id)
      assert {player.fide_id, player.fide_rating, player.club} == {210_999, 1987, "KBSK Brugge"}
    end

    test "an entry arriving while the page is open appears without a reload", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      registration = pending!(t, lotte())
      Tournaments.broadcast_tournament_change(t.id, :registrations)

      assert has_element?(lv, "#registration-#{registration.id}")
    end

    test "a closed form with nothing waiting shows no card", %{conn: conn, scope: scope} do
      t = tournament(scope, open: false)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      refute has_element?(lv, "#registration-queue-card")
    end

    test "an open form with nothing waiting says so", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      assert has_element?(lv, "#registration-queue-card")
      assert has_element?(lv, "#review-entries-link")
      refute has_element?(lv, ".reg-entry")
    end

    test "an id from another tournament is not found, not decided", %{conn: conn, scope: scope} do
      mine = tournament(scope)
      theirs = tournament(scope)
      foreign = pending!(theirs, lotte())

      {:ok, lv, _html} = live(conn, ~p"/t/#{mine.id}/players")
      render_click(lv, "accept", %{"id" => to_string(foreign.id)})

      assert Registrations.pending(theirs.id) != []
      assert Tournaments.list_players(theirs.id) == []
    end
  end

  describe "the Registrations page uses the same queue" do
    test "Accept there creates what the queue shows", %{conn: conn, scope: scope} do
      t = tournament(scope)
      registration = pending!(t, lotte())

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/registrations")
      lv |> element("#accept-registration-#{registration.id}") |> render_click()

      assert [%{name: "Janssens, Lotte"}] = Tournaments.list_players(t.id)
      assert [%{status: "accepted"}] = Registrations.decided(t.id)
    end
  end

  describe "Settings > Results site: when, and how many" do
    test "saves the window, the cap and the list switch", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/results")

      # The hidden fields the `.UtcDateTime` hook fills from the local boxes.
      lv
      |> form("#registration-settings-form")
      |> render_submit(%{
        registration_settings: %{
          registration_opens_at: "2026-10-01T06:00:00.000Z",
          registration_closes_at: "2026-10-20T20:00:00.000Z",
          registration_max_players: "60",
          registration_list_public: "true"
        }
      })

      t = Repo.get!(Tournament, t.id)
      assert t.registration_opens_at == ~U[2026-10-01 06:00:00Z]
      assert t.registration_closes_at == ~U[2026-10-20 20:00:00Z]
      assert t.registration_max_players == 60
      assert t.registration_list_public
    end

    test "a window that closes before it opens is refused, on the page", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/results")

      html =
        lv
        |> form("#registration-settings-form")
        |> render_submit(%{
          registration_settings: %{
            registration_opens_at: "2026-10-20T00:00:00Z",
            registration_closes_at: "2026-10-01T00:00:00Z"
          }
        })

      assert html =~ "must be after the opening time"
      assert Repo.get!(Tournament, t.id).registration_opens_at == nil
    end

    test "empty boxes clear the window", %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, _} =
        Tournaments.set_registration_settings(t, %{
          "registration_opens_at" => "2026-10-01T06:00:00Z",
          "registration_max_players" => "10"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/results")

      lv
      |> form("#registration-settings-form")
      |> render_submit(%{
        registration_settings: %{registration_opens_at: "", registration_max_players: ""}
      })

      t = Repo.get!(Tournament, t.id)
      assert {t.registration_opens_at, t.registration_max_players} == {nil, nil}
    end
  end
end
