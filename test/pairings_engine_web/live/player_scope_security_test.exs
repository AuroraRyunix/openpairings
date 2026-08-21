defmodule PairingsEngineWeb.PlayerScopeSecurityTest do
  @moduledoc """
  Every handler that acts on a client-supplied player id must confirm that
  player belongs to the tournament the socket is authorised for.

  `get_authorized_tournament!/2` gates the TOURNAMENT at mount, but a player
  id arrives later, in the event payload, and is entirely attacker-controlled
  - so authorising the mount proves nothing about the row a handler then goes
  and fetches. Without a scoped lookup, any logged-in user with a tournament
  of their own can name a player id belonging to somebody else's tournament
  and have these handlers act on it.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Player

  setup :register_and_log_in_user

  # A tournament owned by somebody else entirely, holding one player. The
  # attacker is never a collaborator on it and can't open any of its pages.
  defp victim_player(name \\ "Victim") do
    victim = user_scope_fixture()

    {:ok, t} = Tournaments.create_tournament(victim, %{"name" => "Victim's", "type" => "swiss"})
    {:ok, player} = Tournaments.create_player(t.id, %{"name" => name})

    {t, player}
  end

  # The attacker's own tournament, which they legitimately own - this is what
  # gets them a mounted, authorised socket to fire events from.
  defp attacker_tournament(scope) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Attacker's", "type" => "swiss"})
    t
  end

  # The scoped lookup (`Tournaments.get_player/2`) returns nil for a player id
  # outside the socket's tournament, so these handlers refuse the action by
  # doing nothing - a graceful no-op, not a crash. A legitimate user never
  # reaches this path: every id they can click is inside their own tournament.
  # The assertion each test cares about is the security property - the foreign
  # row is untouched and its data is never rendered - not the mechanism.
  test "deleting a player from another user's tournament is refused", %{conn: conn, scope: scope} do
    {_victim_t, victim_player} = victim_player()
    mine = attacker_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{mine.id}/players")

    # The attacker names a player id they were never authorised for - the
    # handler no-ops rather than crashing the socket.
    render_hook(lv, "delete", %{"id" => to_string(victim_player.id)})

    assert Repo.get(Player, victim_player.id), "victim's player must survive"
  end

  test "opening another user's player in the edit dialog is refused", %{conn: conn, scope: scope} do
    {_victim_t, victim_player} = victim_player("Secret Name")
    mine = attacker_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{mine.id}/players")

    # Not just a write bypass: the dialog would otherwise have rendered the
    # foreign player's name, ratings, federation and national id. The no-op
    # leaves the edit dialog closed, so none of that leaks.
    html = render_hook(lv, "edit_player", %{"id" => to_string(victim_player.id)})

    refute html =~ "Secret Name"
  end

  test "reordering another user's player from standings is refused", %{conn: conn, scope: scope} do
    {_victim_t, victim_player} = victim_player()
    mine = attacker_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{mine.id}/standings")

    # Scoped at the fetch: a foreign player id resolves to nil, so the move is
    # a no-op and the victim's manual_rank is never written.
    render_hook(lv, "manual_move", %{
      "player_id" => to_string(victim_player.id),
      "direction" => "up"
    })

    assert Repo.get(Player, victim_player.id).manual_rank == nil,
           "victim's player must not be reordered"
  end

  test "get_player!/2 only finds players inside the given tournament", %{scope: scope} do
    {_victim_t, victim_player} = victim_player()
    mine = attacker_tournament(scope)

    assert_raise Ecto.NoResultsError, fn ->
      Tournaments.get_player!(mine.id, victim_player.id)
    end

    {:ok, own} = Tournaments.create_player(mine.id, %{"name" => "Mine"})
    assert Tournaments.get_player!(mine.id, own.id).id == own.id
  end
end
