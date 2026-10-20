defmodule PairingsEngineWeb.MobileEnrollGuessingTest do
  @moduledoc """
  The `/m` guessing limit, against the one guesser it used to forgive: an
  account that mints its own codes and redeems one between guesses. A
  success no longer wipes the count, and minting is rationed per account.
  """
  use PairingsEngineWeb.ConnCase, async: true

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Mobile, RateLimit, Tournaments}

  # An address of this test's own, so no other test's guesses count here.
  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp tournament(scope) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Guess Open", "type" => "swiss"})
    t
  end

  test "redeeming a good code does not reset the wrong guesses", %{conn: conn} do
    ip = {10, 99, 0, System.unique_integer([:positive]) |> rem(250)}
    key = ip |> :inet.ntoa() |> to_string()
    RateLimit.clear(:mobile_enroll, key)
    on_exit(fn -> RateLimit.clear(:mobile_enroll, key) end)

    scope = user_scope_fixture()
    t = tournament(scope)

    for _ <- 1..3 do
      conn |> from_ip(ip) |> post(~p"/m", %{"code" => "00000001"})
    end

    assert RateLimit.count(:mobile_enroll, key) == 3

    {:ok, e} = Mobile.create_enrollment_for(scope, t.id)
    good = build_conn() |> from_ip(ip) |> post(~p"/m", %{"code" => e.code})
    assert redirected_to(good) == ~p"/m/results"

    # Still three: the right answer proves nothing about the wrong ones.
    assert RateLimit.count(:mobile_enroll, key) == 3
  end

  test "an account mints a limited number of codes an hour" do
    scope = user_scope_fixture()
    t = tournament(scope)
    key = Integer.to_string(scope.user.id)
    on_exit(fn -> RateLimit.clear(:mobile_code_create, key) end)

    for _ <- 1..40, do: assert({:ok, _} = Mobile.create_enrollment_for(scope, t.id))
    assert {:error, :too_many_codes} = Mobile.create_enrollment_for(scope, t.id)

    # Another account's allowance is its own.
    other = user_scope_fixture()
    assert {:ok, _} = Mobile.create_enrollment_for(other, tournament(other).id)
  end

  test "a refused creation is not counted" do
    scope = user_scope_fixture()
    key = Integer.to_string(scope.user.id)
    on_exit(fn -> RateLimit.clear(:mobile_code_create, key) end)

    t = tournament(scope)
    {:ok, _} = Tournaments.archive_tournament(t)

    assert {:error, :archived} = Mobile.create_enrollment_for(scope, t.id)
    assert RateLimit.count(:mobile_code_create, key) == 0
  end
end
