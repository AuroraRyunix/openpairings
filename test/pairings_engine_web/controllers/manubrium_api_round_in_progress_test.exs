defmodule PairingsEngineWeb.ManubriumApiRoundInProgressTest do
  @moduledoc """
  The app against a ten-player Swiss with round 1 played and round 2 half
  entered - the state two reports from the first TestFlight build came
  from:

    * the Standings screen showing the leaders on Buchholz 0 and the
      players on 0 points on Buchholz 1;
    * a queued entry coming back "Board ?: not saved. Check with the
      arbiter." on the organiser's own phone, while the result it was
      blamed on had been saved.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Manubrium, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.Pairing

  @api "/api/manubrium/v1"

  @names ~w(Aerts Bosmans Claes DeSmet Janssens Lambrecht Maes Peeters Vermeulen Willems)

  defp round_in_progress(scope) do
    dates = for r <- 1..5, do: Date.to_iso8601(Date.add(~D[2026-11-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Review Open #{System.unique_integer([:positive])}",
        "type" => "swiss",
        "rounds_count" => "5",
        "round_dates" => dates,
        "start_date" => hd(dates),
        "end_date" => List.last(dates)
      })

    for {name, i} <- Enum.with_index(@names) do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => name,
          "fide_rating" => to_string(2200 - i * 50)
        })
    end

    {:ok, _} = t.id |> Tournaments.get_tournament!() |> Engine.pair_next_round()

    for p <- boards(t, 1) do
      {:ok, _} =
        Tournaments.update_pairing_result(p, if(p.board == 1, do: "1/2-1/2", else: "1-0"))
    end

    {:ok, _} = t.id |> Tournaments.get_tournament!() |> Engine.pair_next_round()

    for p <- boards(t, 2), p.board in [1, 3, 4] do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    Tournaments.get_tournament!(t.id)
  end

  defp boards(t, n) do
    Tournaments.get_round(t.id, n).pairings
    |> Enum.reject(&is_nil(&1.black_player_id))
    |> Enum.sort_by(& &1.board)
  end

  defp board(t, n, number), do: Enum.find(boards(t, n), &(&1.board == number))

  defp token(scope, name \\ "iPhone") do
    {:ok, %{secret: secret}} = Manubrium.create_connect_code(scope, "http://test")
    {:ok, _device, token} = Manubrium.redeem(secret, %{"name" => name}, "10.1.1.1")
    token
  end

  defp phone(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp sync(token, t, entries) do
    build_conn()
    |> phone(token)
    |> post(@api <> "/tournaments/#{t.id}/sync", %{"entries" => entries})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp result_entry(p, round, result, expected \\ "") do
    %{
      "cid" => Ecto.UUID.generate(),
      "kind" => "result",
      "round" => round,
      "pairing" => p.id,
      "board" => p.board,
      "white" => p.white_player_id,
      "black" => p.black_player_id,
      "result" => result,
      "expected" => expected
    }
  end

  # The Standings page's table as `%{player name => %{code => text}}`, read
  # by column header so hidden columns and their order do not matter.
  defp web_tiebreaks(conn, t, codes) do
    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/standings")
    doc = LazyHTML.from_document(html)

    headers =
      doc
      |> LazyHTML.query("table thead th")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    doc
    |> LazyHTML.query("table tbody tr")
    |> Enum.map(fn row ->
      cells = row |> LazyHTML.query("td") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
      name = Enum.find(@names, fn n -> Enum.any?(cells, &String.contains?(&1, n)) end)

      values =
        Map.new(codes, fn code ->
          {code, Enum.at(cells, Enum.find_index(headers, &(&1 == code)))}
        end)

      {name, values}
    end)
    |> Map.new()
  end

  defp shown(value) when is_number(value) do
    if value == Float.round(value * 1.0, 0), do: to_string(trunc(value)), else: to_string(value)
  end

  describe "standings with a round in progress" do
    setup :register_and_log_in_user

    test "the phone gets the Standings page's tie-breaks, cell for cell", %{
      conn: conn,
      scope: scope
    } do
      t = round_in_progress(scope)

      body =
        build_conn()
        |> phone(token(scope))
        |> get(@api <> "/tournaments/#{t.id}/standings")
        |> json_response(200)
        |> Map.fetch!("standings")

      codes = Enum.map(body["tiebreaks"], & &1["code"])
      assert "BH" in codes and "SB" in codes

      web = web_tiebreaks(conn, t, codes)

      for row <- body["rows"] do
        name = row["player"]["name"]

        for code <- codes do
          assert shown(row["tiebreaks"][code]) == web[name][code],
                 "#{name} #{code}: phone #{inspect(row["tiebreaks"][code])}, page #{inspect(web[name][code])}"
        end
      end
    end

    test "says the tie-breaks stop at the last complete round", %{scope: scope} do
      t = round_in_progress(scope)

      body =
        build_conn()
        |> phone(token(scope))
        |> get(@api <> "/tournaments/#{t.id}/standings")
        |> json_response(200)
        |> Map.fetch!("standings")

      # Round 2 is under way: points already count it, tie-breaks do not.
      assert body["rounds_paired"] == 2
      assert body["tiebreaks_through"] == 1

      leader = hd(body["rows"])
      assert leader["points"] == 2.0
      assert leader["tiebreaks"]["BH"] == 0.0

      for p <- boards(t, 2), p.result in [nil, ""] do
        {:ok, _} = Tournaments.update_pairing_result(p, "0-1")
      end

      body =
        build_conn()
        |> phone(token(scope))
        |> get(@api <> "/tournaments/#{t.id}/standings")
        |> json_response(200)
        |> Map.fetch!("standings")

      assert body["tiebreaks_through"] == 2
      assert hd(body["rows"])["tiebreaks"]["BH"] > 0
    end
  end

  describe "the organiser's own queue" do
    setup do
      %{owner: user_scope_fixture()}
    end

    test "a result sent before the phone reconnected, sent again after, is saved", %{
      owner: owner
    } do
      t = round_in_progress(owner)
      p = board(t, 2, 2)
      entry = result_entry(p, 2, "1-0")

      # First send arrives and is saved, but the phone never hears back...
      assert [%{"status" => "saved"}] = sync(token(owner, "iPhone"), t, [entry])

      # ...and it is disconnected and connected again (a new device, a new
      # code) before it sends the queue once more, same cid.
      assert [%{"status" => "saved", "message" => message}] =
               sync(token(owner, "iPhone"), t, [entry])

      assert message =~ "Board 2"
      refute message =~ "arbiter"
      assert Repo.get!(Pairing, p.id).result == "1-0"
    end

    test "an incident with no board is refused by name, not as 'Board ?'", %{owner: owner} do
      t = round_in_progress(owner)

      incident = %{
        "cid" => Ecto.UUID.generate(),
        "kind" => "incident",
        "round" => 2,
        "type" => "arbiter_call",
        "note" => ""
      }

      assert [%{"status" => "refused", "reason" => "no_board", "message" => message}] =
               sync(token(owner), t, [incident])

      refute message =~ "?"
      refute message =~ "arbiter"
    end

    test "a real conflict is still refused, in words for the person who is the arbiter", %{
      owner: owner
    } do
      t = round_in_progress(owner)
      p = board(t, 2, 2)
      {:ok, _} = Tournaments.update_pairing_result(p, "0-1")

      assert [%{"status" => "refused", "reason" => "conflict", "message" => message}] =
               sync(token(owner), t, [result_entry(p, 2, "1-0")])

      assert message =~ "Board 2"
      assert message =~ "0-1"
      refute message =~ "Check with the arbiter"
      assert Repo.get!(Pairing, p.id).result == "0-1"
    end

    test "an entry the server cannot read is refused with its board, never silently", %{
      owner: owner
    } do
      t = round_in_progress(owner)
      p = board(t, 2, 2)
      broken = Map.put(result_entry(p, 2, "1-0"), "round", "two")

      assert [%{"status" => "refused", "message" => message}] = sync(token(owner), t, [broken])
      assert message =~ "Board 2"
      refute message =~ "Check with the arbiter"
    end
  end
end
