defmodule PairingsEngineWeb.SettingsRoomsLiveTest do
  @moduledoc """
  Settings, Rooms: adding, renaming and removing rooms with the checker
  speaking up as you type, and the rooms showing up where boards are
  listed - the pairing list and the printed pairings - only once there are
  any.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Rooms LV", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    t
  end

  # Six players, three boards in round 1.
  defp paired(t) do
    players =
      for n <- 1..6 do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: "Player #{n}",
          fide_rating: 2000 - n,
          pairing_number: n
        })
      end

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "playing"})

    for {[w, b], board} <- players |> Enum.chunk_every(2) |> Enum.with_index(1) do
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: w.id,
        black_player_id: b.id
      })
    end

    t
  end

  test "the page is in the rail and starts empty", %{conn: conn, scope: scope} do
    t = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/rooms")

    assert has_element?(lv, "#settings-nav a[href='/t/#{t.id}/settings/rooms']")
    assert has_element?(lv, "#rooms-empty")
    refute has_element?(lv, "#settings-advanced-toggle")
  end

  test "add, type, see the feedback, save", %{conn: conn, scope: scope} do
    t = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/rooms")

    lv |> element("#rooms-add") |> render_click()
    lv |> element("#rooms-add") |> render_click()
    assert has_element?(lv, "#room-1")

    lv
    |> form("#rooms-form", %{
      "rooms" => %{
        "0" => %{"name" => "Main hall", "boards" => "1-10"},
        "1" => %{"name" => "Annexe", "boards" => "8-12"}
      }
    })
    |> render_change()

    assert has_element?(lv, "#room-0-feedback.hint")
    assert has_element?(lv, "#room-1-feedback.error-note", "Board 8 is already in Main hall")

    lv
    |> form("#rooms-form", %{
      "rooms" => %{
        "0" => %{"name" => "Main hall", "boards" => "1-10"},
        "1" => %{"name" => "Annexe", "boards" => "11-x"}
      }
    })
    |> render_submit()

    assert has_element?(lv, ".tset-error")
    assert Tournaments.get_tournament!(t.id).rooms == []

    lv
    |> form("#rooms-form", %{
      "rooms" => %{
        "0" => %{"name" => "Main hall", "boards" => "1 - 10"},
        "1" => %{"name" => "Annexe", "boards" => "11-12"}
      }
    })
    |> render_submit()

    assert [%{"name" => "Main hall", "boards" => "1-10"}, %{"name" => "Annexe"}] =
             Tournaments.get_tournament!(t.id).rooms
  end

  test "renaming keeps the id; removing drops the room", %{conn: conn, scope: scope} do
    t =
      tournament(scope, %{
        "rooms" => [
          %{"name" => "Main", "boards" => "1-10"},
          %{"name" => "Annexe", "boards" => "11-20"}
        ]
      })

    [%{"id" => main_id}, _] = t.rooms
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/rooms")

    lv |> element("#room-1-remove") |> render_click()
    refute has_element?(lv, "#room-1")

    lv
    |> form("#rooms-form", %{"rooms" => %{"0" => %{"name" => "Big hall", "boards" => "1-10"}}})
    |> render_submit()

    assert [%{"id" => ^main_id, "name" => "Big hall"}] = Tournaments.get_tournament!(t.id).rooms
  end

  test "the pairing list names a room on its first board only", %{conn: conn, scope: scope} do
    t = scope |> tournament() |> paired()

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    refute has_element?(lv, ".pairing-room")

    {:ok, _} =
      Tournaments.update_tournament(Tournaments.get_tournament!(t.id), %{
        "rooms" => [
          %{"name" => "Main", "boards" => "1-2"},
          %{"name" => "Annexe", "boards" => "3"}
        ]
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    assert has_element?(lv, ".pairing-room", "Main")
    assert has_element?(lv, ".pairing-room", "Annexe")

    assert lv
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".pairing-room")
           |> Enum.count() == 2
  end

  test "the printed pairings get a Room column only with rooms", %{conn: conn, scope: scope} do
    t = scope |> tournament() |> paired()

    html = conn |> get(~p"/t/#{t.id}/print/pairings?round=1") |> html_response(200)
    refute html =~ ~s(class="room")

    {:ok, _} =
      Tournaments.update_tournament(Tournaments.get_tournament!(t.id), %{
        "rooms" => [%{"name" => "Annexe", "boards" => "3"}]
      })

    html = conn |> get(~p"/t/#{t.id}/print/pairings?round=1") |> html_response(200)
    assert html =~ ~s(<th class="room">Room</th>)
    assert html =~ ~s(<td class="room">Annexe</td>)

    html = conn |> get(~p"/t/#{t.id}/print/pairings-alpha?round=1") |> html_response(200)
    assert html =~ ~s(<td class="room">Annexe</td>)
  end
end
