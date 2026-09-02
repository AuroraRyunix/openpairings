defmodule PairingsEngineWeb.MobileEnrollControllerTest do
  @moduledoc """
  The public code-entry route (`POST /m`). Unauthenticated, so what it does
  with a code it cannot resolve matters as much as what it does with one it
  can.
  """
  use PairingsEngineWeb.ConnCase, async: true

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Mobile, RateLimit, Repo}
  alias PairingsEngine.Mobile.Enrollment
  alias PairingsEngine.Tournaments

  setup do
    RateLimit.clear(:mobile_enroll, "127.0.0.1")
    on_exit(fn -> RateLimit.clear(:mobile_enroll, "127.0.0.1") end)
    :ok
  end

  defp tournament do
    scope = user_scope_fixture()
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Enrol Test", "type" => "swiss"})
    t
  end

  test "a good code enrolls the browser", %{conn: conn} do
    {:ok, e} = Mobile.create_enrollment(tournament().id)

    conn = post(conn, ~p"/m", %{"code" => e.code})

    assert redirected_to(conn) == ~p"/m/results"
    assert get_session(conn, :mobile_enrollment_id) == e.id
  end

  test "an unknown code is answered, not raised on", %{conn: conn} do
    conn = post(conn, ~p"/m", %{"code" => "12345678"})

    assert html_response(conn, 200) =~ "wrong or has expired"
  end

  test "two active enrollments sharing a code do not turn the submit into a 500", %{conn: conn} do
    # The reproduction: `get_active_by_code/1` was `Repo.one`, which answers
    # a second match by raising `Ecto.MultipleResultsError`, and nothing on
    # this public path rescues. The partial unique index now makes the pair
    # impossible, so it is dropped here to stand in for a database that has
    # drifted anyway - a restored backup, a hand-edited row. The sandbox
    # transaction rolls the DDL back with the rest of the test.
    t = tournament()
    {:ok, first} = Mobile.create_enrollment(t.id)

    Repo.query!("DROP INDEX mobile_enrollments_active_code_index")

    second =
      Repo.insert!(%Enrollment{
        tournament_id: t.id,
        token: "a-second-token",
        code: first.code,
        label: "",
        expires_at: first.expires_at
      })

    conn = post(conn, ~p"/m", %{"code" => first.code})

    assert redirected_to(conn) == ~p"/m/results"
    assert get_session(conn, :mobile_enrollment_id) == second.id
  end
end
