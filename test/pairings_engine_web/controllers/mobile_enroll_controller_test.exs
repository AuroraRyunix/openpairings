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

  describe "one device per code" do
    test "a first scan via the QR token claims the phone", %{conn: conn} do
      {:ok, e} = Mobile.create_enrollment(tournament().id)

      conn = get(conn, ~p"/m/e/#{e.token}")

      assert redirected_to(conn) == ~p"/m/results"
      assert get_session(conn, :mobile_enrollment_id) == e.id
      assert %DateTime{} = Repo.get!(Enrollment, e.id).claimed_at
    end

    test "a second scan of the same token is refused and does not get a session", %{conn: conn} do
      {:ok, e} = Mobile.create_enrollment(tournament().id)

      _first = get(conn, ~p"/m/e/#{e.token}")
      second = get(build_conn(), ~p"/m/e/#{e.token}")

      assert html_response(second, 200) =~ "already been used by another phone"
      assert get_session(second, :mobile_enrollment_id) == nil
    end

    test "a first scan of the 6-digit code claims the phone", %{conn: conn} do
      {:ok, e} = Mobile.create_enrollment(tournament().id)

      conn = post(conn, ~p"/m", %{"code" => e.code})

      assert redirected_to(conn) == ~p"/m/results"
      assert %DateTime{} = Repo.get!(Enrollment, e.id).claimed_at
    end

    test "a second submit of the same code is refused and does not get a session", %{conn: conn} do
      {:ok, e} = Mobile.create_enrollment(tournament().id)

      _first = post(conn, ~p"/m", %{"code" => e.code})
      second = post(build_conn(), ~p"/m", %{"code" => e.code})

      assert html_response(second, 200) =~ "already been used by another phone"
      assert get_session(second, :mobile_enrollment_id) == nil
    end

    test "a revoked code still says so, not that it was already used", %{conn: conn} do
      {:ok, e} = Mobile.create_enrollment(tournament().id)
      {:ok, _} = Mobile.revoke(e)

      by_code = post(conn, ~p"/m", %{"code" => e.code})
      refute html_response(by_code, 200) =~ "already been used by another phone"
      assert html_response(by_code, 200) =~ "wrong or has expired"

      by_token = get(build_conn(), ~p"/m/e/#{e.token}")
      refute html_response(by_token, 200) =~ "already been used by another phone"
      assert html_response(by_token, 200) =~ "invalid or has expired"
    end

    test "an expired code still says so, not that it was already used", %{conn: conn} do
      {:ok, e} = Mobile.create_enrollment(tournament().id, ttl_hours: 1)
      past = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
      e |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      by_code = post(conn, ~p"/m", %{"code" => e.code})
      refute html_response(by_code, 200) =~ "already been used by another phone"
      assert html_response(by_code, 200) =~ "wrong or has expired"

      by_token = get(build_conn(), ~p"/m/e/#{e.token}")
      refute html_response(by_token, 200) =~ "already been used by another phone"
      assert html_response(by_token, 200) =~ "invalid or has expired"
    end
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
