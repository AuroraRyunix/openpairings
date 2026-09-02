defmodule PairingsEngineWeb.FideLookupControllerTest do
  @moduledoc """
  Lending the FIDE list to the results site.

  The list lives here because this is the machine that pairs from it. The
  entry form moved to OpenResults on 2026-08-29 and the list did not, so this
  is how the form gets the search it used to have.

  The list itself is public - FIDE distributes it. What the token and the rate
  limit protect is the machine: an arbiter's laptop in the middle of a round
  should not be anybody's free search API.
  """
  use PairingsEngineWeb.ConnCase, async: false

  alias PairingsEngine.{Fide, Publishing, RateLimit, Repo}
  alias PairingsEngine.Fide.FidePlayer

  setup do
    # No `reset/0` on this limiter - it clears per key, and every request in
    # this file comes from the same test address.
    RateLimit.clear(:fide_lookup, "127.0.0.1")
    Publishing.put_token("s3cret")

    Repo.insert!(%FidePlayer{
      fide_id: 2_503_014,
      name: "De Vos, Ilse",
      title: "WFM",
      federation: "BEL",
      birth_year: 1994,
      standard_rating: 1804,
      rapid_rating: 1750,
      blitz_rating: 1700
    })

    :ok
  end

  defp authed(conn, token \\ "s3cret") do
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  describe "who may ask" do
    test "a caller with the publishing token", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos")

      assert %{"players" => [player]} = json_response(conn, 200)
      assert player["name"] == "De Vos, Ilse"
    end

    test "nobody without one", %{conn: conn} do
      conn = get(conn, ~p"/internal/fide/search", q: "De Vos")

      assert json_response(conn, 401)
    end

    test "nor with the wrong one", %{conn: conn} do
      conn = conn |> authed("not-the-token") |> get(~p"/internal/fide/search", q: "De Vos")

      assert json_response(conn, 401)
    end

    test "and nobody at all on a machine that has never been configured", %{conn: conn} do
      # Fails closed. A fresh install answering unauthenticated searches would
      # be an open endpoint on every arbiter's laptop.
      Publishing.put_token(nil)

      conn = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos")

      assert json_response(conn, 401)
    end
  end

  describe "what comes back" do
    test "the fields the entry form needs, named as the form names them", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos")

      assert %{"players" => [player]} = json_response(conn, 200)

      assert Enum.sort(Map.keys(player)) ==
               ~w(birth_year federation fide_id name rating title)

      # So the results site fills its form without translating anything.
      assert player["federation"] == "BEL"
      assert player["title"] == "WFM"
      assert player["birth_year"] == 1994
    end

    test "the rating for the tournament's own tempo", %{conn: conn} do
      standard = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos")
      rapid = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos", tempo: "rapid")
      blitz = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos", tempo: "blitz")

      # A player entered at their standard rating in a blitz tournament is
      # seeded wrong, and the arbiter would have to notice and fix it.
      assert hd(json_response(standard, 200)["players"])["rating"] == 1804
      assert hd(json_response(rapid, 200)["players"])["rating"] == 1750
      assert hd(json_response(blitz, 200)["players"])["rating"] == 1700
    end

    test "a blank title or federation is null, not an empty string", %{conn: conn} do
      Repo.insert!(%FidePlayer{fide_id: 9_000_001, name: "Untitled, Player"})

      conn = conn |> authed() |> get(~p"/internal/fide/search", q: "Untitled")

      assert %{"players" => [player]} = json_response(conn, 200)
      assert player["title"] == nil
      assert player["federation"] == nil
    end

    test "nothing for a query too short to mean anything", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/internal/fide/search", q: "D")

      assert json_response(conn, 200)["players"] == []
    end

    test "a FIDE ID finds exactly that player", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/internal/fide/search", q: "2503014")

      assert [%{"fide_id" => 2_503_014}] = json_response(conn, 200)["players"]
    end

    # An all-digit query used to go straight into `Repo.get/2` as an
    # arbitrary-precision integer, and Exqlite raises on anything wider than
    # 64 bits - taking this endpoint (and every other caller of
    # `Fide.search/1`) down with an "argument error".
    test "an absurdly long number is simply no match", %{conn: conn} do
      huge = String.duplicate("9", 25)

      assert Fide.search(huge) == []
      assert Fide.search(to_string(PairingsEngine.Tournaments.Player.max_fide_id() + 1)) == []
      assert Fide.search("00") == []
      assert Fide.get_player(huge) == nil

      conn = conn |> authed() |> get(~p"/internal/fide/search", q: huge)
      assert json_response(conn, 200)["players"] == []
    end
  end

  describe "the rate limit" do
    test "a flood is refused, and says so in a way a client can act on", %{conn: conn} do
      # The bucket allows 60 a minute - a person typing a surname fires a
      # handful. Anything past this is not typing.
      for _ <- 1..60 do
        conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos")
      end

      refused = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos")

      assert json_response(refused, 429)
    end

    test "and it is counted after authorisation, not before", %{conn: conn} do
      # An unauthorised caller must not be able to use up an authorised one's
      # allowance - they share an address whenever both come through the same
      # proxy, which on the hosted deployment is always.
      for _ <- 1..60 do
        get(conn, ~p"/internal/fide/search", q: "De Vos")
      end

      allowed = conn |> authed() |> get(~p"/internal/fide/search", q: "De Vos")

      assert json_response(allowed, 200)
    end
  end

  describe "the list itself" do
    test "is not exposed wholesale", %{conn: conn} do
      for n <- 1..30 do
        Repo.insert!(%FidePlayer{fide_id: 8_000_000 + n, name: "Vos, Common Name #{n}"})
      end

      conn = conn |> authed() |> get(~p"/internal/fide/search", q: "Vos")

      # Answers "which of these is me", not "give me the list". Somebody who
      # needs all of it should get it from FIDE.
      assert length(json_response(conn, 200)["players"]) <= 15
    end

    test "Fide.search/1 is what decides matches, not this controller" do
      # Guards against the endpoint growing its own matching rules that drift
      # from the ones the arbiter's own screens use.
      assert Fide.search("De Vos") |> Enum.map(& &1.fide_id) == [2_503_014]
    end
  end
end
