defmodule PairingsEngineWeb.ForceUnlockPanelTest do
  @moduledoc """
  The break-glass affordance, checked for the two things that make it safe:
  it is hard to reach by accident, and the words next to it are true.

  A confirmation that says "are you sure?" tests nothing. The sentence this
  panel has to put in front of an arbiter is the one they will not think of
  on their own - that the other copy is still out there, that unlocking here
  does not close it, and that whoever holds it must never open it again.
  """
  use PairingsEngine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngineWeb.SettingsSupport

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "panel#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Panel Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    t
  end

  defp render_panel(tournament, scope, opts \\ []) do
    render_component(&SettingsSupport.force_unlock_panel/1, %{
      tournament: tournament,
      scope: scope,
      confirm_text: Keyword.get(opts, :confirm_text, ""),
      error: Keyword.get(opts, :error)
    })
  end

  test "renders nothing at all for a tournament that is live here" do
    scope = user_scope()

    html = render_panel(tournament(scope), scope)

    refute html =~ "force-unlock"
    refute html =~ "UNLOCK"
  end

  test "renders nothing for a collaborator - forcing the lock is the owner's call" do
    owner = user_scope()
    {:ok, handed} = Tournaments.hand_off(tournament(owner), "the club PC")

    refute render_panel(handed, user_scope()) =~ "force-unlock"
  end

  test "says the true thing: the other copy exists and must never be opened again" do
    scope = user_scope()
    {:ok, handed} = Tournaments.hand_off(tournament(scope), "the club PC")

    html = render_panel(handed, scope)

    assert html =~ "the club PC"
    assert html =~ "still exists"
    assert html =~ "never open it again"
    assert html =~ "does not merge anything back"
    assert html =~ "audit trail"
  end

  test "is folded away rather than sitting out in the open" do
    scope = user_scope()
    {:ok, handed} = Tournaments.hand_off(tournament(scope), "the club PC")

    html = render_panel(handed, scope)

    assert html =~ "<details"
    assert html =~ "<summary"
  end

  test "the button is disabled until the word is typed, exactly" do
    scope = user_scope()
    {:ok, handed} = Tournaments.hand_off(tournament(scope), "the club PC")

    assert render_panel(handed, scope) =~ "disabled"
    assert render_panel(handed, scope, confirm_text: "unlock") =~ "disabled"
    assert render_panel(handed, scope, confirm_text: "UNLOCK ") =~ "disabled"
    refute render_panel(handed, scope, confirm_text: "UNLOCK") =~ "disabled"
  end

  test "names a destination it does not know rather than rendering a blank" do
    scope = user_scope()
    {:ok, handed} = Tournaments.hand_off(tournament(scope), "")

    assert render_panel(handed, scope) =~ "another copy"
  end

  test "shows a refusal from the context when the page hands one back" do
    scope = user_scope()
    {:ok, handed} = Tournaments.hand_off(tournament(scope), "the club PC")

    assert render_panel(handed, scope, error: SettingsSupport.error_text(:not_owner)) =~
             "Only the owner"
  end
end
