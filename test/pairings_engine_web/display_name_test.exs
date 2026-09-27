defmodule PairingsEngineWeb.DisplayNameTest do
  @moduledoc """
  Account → Profile's display name, where the app names a person: the audit
  log, the history, the sharing list, a pending invitation and the
  invitation page. The address never disappears - a chosen name is not
  unique - it moves beside the name or into a tooltip.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Accounts, Audit, Tournaments}
  alias PairingsEngine.Accounts.Scope

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, user} = Accounts.update_user_profile(user, %{"display_name" => "Jan Peeters"})
    scope = Scope.for_user(user)
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Zomer", "rounds_count" => 3})
    %{user: user, scope: scope, tournament: t}
  end

  test "the audit log shows the name, with the address in the tooltip", %{
    conn: conn,
    user: user,
    scope: scope,
    tournament: t
  } do
    {:ok, _} = Audit.log(t.id, scope, "tournament.created", %{name: t.name})
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/audit")

    assert has_element?(lv, "td[title='#{user.email}']", "Jan Peeters")
  end

  test "the history shows the name on a restore point", %{conn: conn, scope: scope, tournament: t} do
    {:ok, _} =
      PairingsEngine.Snapshots.capture(t, "snapshot.manual", scope, summary: "Before round 1")

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/history")

    assert html =~ "Jan Peeters"
  end

  test "the sharing list shows a collaborator's name above the address", %{
    conn: conn,
    scope: scope,
    tournament: t
  } do
    colleague = user_fixture()
    {:ok, _} = Accounts.update_user_profile(colleague, %{"display_name" => "Els Janssens"})
    {:ok, _} = Tournaments.add_collaborator(scope, t, colleague.email)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")

    assert has_element?(lv, ".collab-name", "Els Janssens")
    assert render(lv) =~ colleague.email
  end

  test "an invitation names the owner by name and address", %{
    user: owner,
    scope: scope,
    tournament: t
  } do
    invitee = user_fixture()
    {:ok, c} = Tournaments.add_collaborator(scope, t, invitee.email)
    conn = log_in_user(build_conn(), invitee)

    {:ok, _lv, html} = live(conn, ~p"/invites/#{c.invite_token}")
    assert html =~ "Jan Peeters (#{owner.email})"

    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, ".collab-name", "Jan Peeters")
  end

  test "the invitation email names the owner by name and address", %{
    user: owner,
    scope: scope,
    tournament: t
  } do
    invitee_email = unique_user_email()
    {:ok, _} = Tournaments.add_collaborator(scope, t, invitee_email)

    assert Enum.any?(sent_emails(), fn email ->
             Enum.any?(email.to, fn {_name, address} -> address == invitee_email end) and
               email.text_body =~ "Jan Peeters (#{owner.email})"
           end)
  end

  # Every email the test adapter has delivered to this process so far - the
  # fixtures send sign-in mail of their own before the one under test.
  defp sent_emails(acc \\ []) do
    receive do
      {:email, email} -> sent_emails([email | acc])
    after
      0 -> acc
    end
  end
end
