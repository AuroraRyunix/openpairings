defmodule PairingsEngineWeb.MobileAppControllerTest do
  @moduledoc """
  Manubrium's three routes (docs/manubrium.md): the manifest, the service
  worker, and `POST /m/sync`, which judges a phone's queue against the
  enrolment in ITS session - never one an entry names.
  """
  use PairingsEngineWeb.ConnCase

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Mobile, Repo, Tournaments}
  alias PairingsEngine.Mobile.Sync
  alias PairingsEngine.Tournaments.{Pairing, Round}

  defp board(level \\ "helper") do
    {:ok, t} =
      Tournaments.create_tournament(user_scope_fixture(), %{"name" => "App T", "type" => "swiss"})

    {:ok, w} = Tournaments.create_player(t.id, %{"name" => "Wim", "fide_rating" => "1800"})
    {:ok, b} = Tournaments.create_player(t.id, %{"name" => "Bea", "fide_rating" => "1700"})
    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "paired"})

    p =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 7,
        white_player_id: w.id,
        black_player_id: b.id,
        result: ""
      })

    {:ok, e} = Mobile.create_enrollment(t.id, level: level)
    %{t: t, e: e, p: p}
  end

  defp entry(e, p, result, extra \\ %{}) do
    Map.merge(
      %{
        "cid" => Ecto.UUID.generate(),
        "enrollment" => e.id,
        "kind" => "result",
        "round" => 1,
        "pairing" => p.id,
        "board" => p.board,
        "white" => p.white_player_id,
        "black" => p.black_player_id,
        "result" => result,
        "expected" => ""
      },
      extra
    )
  end

  defp sync(conn, enrollment_id, entries) do
    conn
    |> init_test_session(%{mobile_enrollment_id: enrollment_id})
    |> put_req_header("accept", "application/json")
    |> post(~p"/m/sync", %{"entries" => entries})
  end

  describe "the manifest" do
    test "names Manubrium, starts at the result page and stays inside /m", %{conn: conn} do
      conn = get(conn, ~p"/m/manifest.webmanifest")

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/manifest+json"

      manifest = Jason.decode!(conn.resp_body)
      assert manifest["name"] == "Manubrium"
      assert manifest["short_name"] == "Manubrium"
      assert manifest["start_url"] == "/m/results"
      assert manifest["scope"] == "/m/"
      assert manifest["display"] == "standalone"
      assert Enum.any?(manifest["icons"], &(&1["purpose"] == "maskable"))
      assert Enum.all?(manifest["icons"], &String.starts_with?(&1["src"], "/images/manubrium/"))
    end
  end

  describe "the service worker" do
    test "is JavaScript with its placeholders filled in and no cache of its own", %{conn: conn} do
      conn = get(conn, ~p"/m/sw.js")

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "javascript"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]

      body = conn.resp_body
      refute body =~ "__MANUBRIUM_VERSION__"
      refute body =~ "__MANUBRIUM_TEXT__"
      assert body =~ ~s(const VERSION = "#{PairingsEngine.Build.version()}-)
      assert body =~ "Manubrium is offline"
    end

    test "caches nothing but the result page and the public bundles", %{conn: conn} do
      body = get(conn, ~p"/m/sw.js").resp_body

      # The one page it ever puts in its cache, under one fixed key.
      assert body =~ ~s("/m/results")
      refute body =~ "cache.addAll"
    end
  end

  describe "POST /m/sync" do
    test "answers each entry with a sentence that names the board", %{conn: conn} do
      %{e: e, p: p} = board()
      first = entry(e, p, "1/2-1/2")

      body = conn |> sync(e.id, [first]) |> json_response(200)

      assert [%{"cid" => cid, "status" => "saved", "message" => message}] = body["results"]
      assert cid == first["cid"]
      assert message =~ "Board 7"
      assert Repo.get!(Pairing, p.id).result == "1/2-1/2"
    end

    test "a refusal comes back with its reason and the board's current result", %{conn: conn} do
      %{e: e, p: p} = board("deputy")
      {:ok, _} = Tournaments.update_pairing_result(p, "0-1")

      [answer] =
        conn |> sync(e.id, [entry(e, p, "1-0")]) |> json_response(200) |> Map.get("results")

      assert answer["status"] == "refused"
      assert answer["reason"] == "conflict"
      assert answer["message"] =~ "Board 7"
      assert answer["message"] =~ "0-1"
      assert Repo.get!(Pairing, p.id).result == "0-1"
    end

    test "with no enrolment in the session every entry is refused as revoked", %{conn: conn} do
      %{e: e, p: p} = board()

      [answer] =
        conn
        |> put_req_header("accept", "application/json")
        |> post(~p"/m/sync", %{"entries" => [entry(e, p, "1-0")]})
        |> json_response(200)
        |> Map.get("results")

      assert answer["reason"] == "revoked"
      assert answer["message"] =~ "Board 7"
      assert Repo.get!(Pairing, p.id).result == ""
    end

    test "a revoked enrolment in the session is refused the same way", %{conn: conn} do
      %{e: e, p: p} = board()
      {:ok, _} = Mobile.revoke(e)

      [answer] =
        conn |> sync(e.id, [entry(e, p, "1-0")]) |> json_response(200) |> Map.get("results")

      assert {answer["status"], answer["reason"]} == {"refused", "revoked"}
      assert Repo.get!(Pairing, p.id).result == ""
    end

    test "an entry naming another enrolment does not borrow it", %{conn: conn} do
      %{e: mine, p: p} = board("helper")
      %{e: theirs} = board("deputy")

      [answer] =
        conn
        |> sync(mine.id, [entry(theirs, p, "1-0")])
        |> json_response(200)
        |> Map.get("results")

      assert answer["reason"] == "other_code"
      assert Repo.get!(Pairing, p.id).result == ""
    end

    test "too many entries in one request is a 413", %{conn: conn} do
      %{e: e, p: p} = board()
      entries = for _ <- 0..Sync.max_batch(), do: entry(e, p, "1-0")

      assert %{"error" => "too_many"} = conn |> sync(e.id, entries) |> json_response(413)
    end

    test "a body without entries is a 400", %{conn: conn} do
      %{e: e} = board()

      conn =
        conn
        |> init_test_session(%{mobile_enrollment_id: e.id})
        |> put_req_header("accept", "application/json")
        |> post(~p"/m/sync", %{"entries" => "nope"})

      assert %{"error" => "bad_request"} = json_response(conn, 400)
    end
  end

  describe "where the manifest is linked" do
    test "on Manubrium's pages", %{conn: conn} do
      html = conn |> get(~p"/m") |> html_response(200)

      assert html =~ ~s(rel="manifest")
      assert html =~ "/m/manifest.webmanifest"
      assert html =~ ~s(id="manubrium-install-hint")
    end

    test "and not on the rest of the app", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      refute html =~ "manifest.webmanifest"
    end
  end
end
