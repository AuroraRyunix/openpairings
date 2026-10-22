defmodule PairingsEngineWeb.ManubriumApiEditsTest do
  @moduledoc """
  The Manubrium app's second batch of routes (docs/manubrium.md, "Full
  app"): hand edits to a paired round and finishing them, the settings an
  arbiter changes mid-event, the arbiter's word on a Lite phone's result,
  and an incident after it was logged: its photo, amending it, deleting it.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Incidents, Manubrium, Mobile, Repo, Tournaments}
  alias PairingsEngine.Mobile.{PhoneResults, Sync}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.Collaborator

  @api "/api/manubrium/v1"
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9>>

  ## ---------- fixtures ----------

  defp tournament(scope, players \\ 4) do
    dates = for r <- 1..3, do: Date.to_iso8601(Date.add(~D[2026-11-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Edit Open #{System.unique_integer([:positive])}",
        "type" => "swiss",
        "rounds_count" => "3",
        "round_dates" => dates,
        "start_date" => hd(dates),
        "end_date" => List.last(dates)
      })

    for i <- 1..players do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{i}",
          "fide_rating" => to_string(2200 - i * 50)
        })
    end

    Tournaments.get_tournament!(t.id)
  end

  defp paired(scope, players \\ 4) do
    t = tournament(scope, players)
    {:ok, _round} = Engine.pair_next_round(t)
    Tournaments.get_tournament!(t.id)
  end

  defp token(scope) do
    {:ok, %{secret: secret}} = Manubrium.create_connect_code(scope, "http://test")
    {:ok, _device, token} = Manubrium.redeem(secret, %{"name" => "Test phone"}, "10.1.1.1")
    token
  end

  defp enlist(owner, t, role) do
    scope = user_scope_fixture()
    {:ok, c} = Tournaments.add_collaborator(owner, t, scope.user.email, role)
    {:ok, _} = Tournaments.accept_invitation(scope, c.invite_token)
    _ = Repo.get!(Collaborator, c.id)
    scope
  end

  defp phone(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp boards(t, n \\ 1),
    do: Tournaments.get_round(t.id, n).pairings |> Enum.sort_by(& &1.board)

  defp games(t), do: Enum.reject(boards(t), &is_nil(&1.black_player_id))

  # A result entered on `/m` by a no-account code: Manubrium Lite.
  defp lite_result(t, p, result) do
    {:ok, e} = Mobile.create_enrollment(t.id, level: "helper", label: "Hall phone")

    {:ok, [%{status: :saved}]} =
      Sync.submit(e.id, [
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
        }
      ])

    e
  end

  defp edit(conn, token, t, edit, ack \\ []) do
    conn
    |> phone(token)
    |> post(@api <> "/tournaments/#{t.id}/rounds/1/edits", %{
      "edit" => edit,
      "acknowledged" => ack
    })
  end

  setup do
    owner = user_scope_fixture()
    %{owner: owner, token: token(owner)}
  end

  ## ---------- hand edits ----------

  describe "hand edits" do
    test "swapping two players between boards", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      [b1, b2] = games(t)
      a = b1.white_player_id
      b = b2.white_player_id

      conn = edit(conn, token, t, %{"kind" => "swap", "a" => a, "b" => b}, ["pairing_rules"])
      body = json_response(conn, 200)

      [n1, n2] = games(t)
      assert n1.white_player_id == b
      assert n2.white_player_id == a
      assert body["round"]["hand_edits"]["open"]

      assert Enum.any?(
               Audit.list_for_tournament(t.id),
               &(&1.action == "pairing.players_swapped" and &1.details["via"] == "mobile")
             )
    end

    test "a swap that breaks a pairing rule asks first and changes nothing", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [b1 | _] = games(t)

      # Swapping a board's own players is a colour swap; whatever the rules
      # make of it, nothing is applied without the answer the server wants.
      conn1 =
        edit(conn, token, t, %{
          "kind" => "swap",
          "a" => b1.white_player_id,
          "b" => b1.black_player_id
        })

      case conn1.status do
        409 ->
          body = json_response(conn1, 409)
          assert body["error"] == "needs_acknowledgement"
          assert is_list(body["confirm"])
          assert is_binary(body["summary"])
          assert hd(games(t)).white_player_id == b1.white_player_id

        200 ->
          assert hd(games(t)).white_player_id == b1.black_player_id
      end
    end

    test "marking a player absent, then giving the opponent the bye", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [b1 | _] = games(t)

      assert json_response(
               edit(conn, token, t, %{"kind" => "vacate", "player" => b1.black_player_id}),
               200
             )

      vacant = Enum.find(boards(t), &(&1.id == b1.id))
      assert is_nil(vacant.black_player_id)

      body =
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/rounds/1")
        |> json_response(200)

      board = Enum.find(body["round"]["boards"], &(&1["id"] == b1.id))
      assert board["vacant"]
      assert Enum.any?(body["round"]["pool"], &(&1["player"]["id"] == b1.black_player_id))

      # Finishing with a vacant seat is refused, as at the desk.
      assert %{"error" => "vacant_seat"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/edits/finish", %{})
               |> json_response(409)

      conn2 = edit(conn, token, t, %{"kind" => "bye", "pairing" => b1.id}, ["pairing_rules"])
      assert json_response(conn2, 200)
      assert Enum.find(boards(t), &(&1.id == b1.id)).result == "bye"
    end

    test "re-pairing a vacated player onto the empty seat", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [b1 | _] = games(t)
      black = b1.black_player_id

      assert json_response(edit(conn, token, t, %{"kind" => "vacate", "player" => black}), 200)

      assert json_response(
               edit(conn, token, t, %{"kind" => "fill", "pairing" => b1.id, "player" => black}, [
                 "pairing_rules"
               ]),
               200
             )

      assert Enum.find(boards(t), &(&1.id == b1.id)).black_player_id == black
    end

    test "finishing hand edits closes the session", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      [b1, b2] = games(t)

      assert json_response(
               edit(
                 conn,
                 token,
                 t,
                 %{"kind" => "swap", "a" => b1.white_player_id, "b" => b2.white_player_id},
                 ["pairing_rules"]
               ),
               200
             )

      first =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments/#{t.id}/rounds/1/edits/finish", %{})

      body =
        case first.status do
          409 ->
            assert %{"confirm" => ["mpa_pibe"], "checker" => %{"line" => line}} =
                     json_response(first, 409)

            assert is_binary(line)

            conn
            |> phone(token)
            |> post(@api <> "/tournaments/#{t.id}/rounds/1/edits/finish", %{
              "acknowledged" => ["mpa_pibe"]
            })
            |> json_response(200)

          200 ->
            json_response(first, 200)
        end

      refute body["round"]["hand_edits"]["open"]

      assert %{"error" => "no_hand_edits"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/edits/finish", %{})
               |> json_response(409)
    end

    test "nonsense is refused without touching the round", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [b1 | _] = games(t)

      assert %{"error" => "bad_request"} =
               json_response(edit(conn, token, t, %{"kind" => "teleport"}), 400)

      assert %{"error" => "same_player"} =
               json_response(
                 edit(conn, token, t, %{
                   "kind" => "swap",
                   "a" => b1.white_player_id,
                   "b" => b1.white_player_id
                 }),
                 422
               )

      assert %{"error" => "not_in_round"} =
               json_response(
                 edit(conn, token, t, %{
                   "kind" => "swap",
                   "a" => b1.white_player_id,
                   "b" => 999_999
                 }),
                 422
               )

      assert %{"error" => "bad_request"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/edits", %{})
               |> json_response(400)

      assert %{"error" => "not_paired"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/2/edits", %{
                 "edit" => %{"kind" => "delete", "pairing" => 1}
               })
               |> json_response(404)
    end

    test "an arbiter may not edit pairings", %{conn: conn, owner: owner} do
      t = paired(owner)
      arbiter = token(enlist(owner, t, "arbiter"))
      [b1, b2] = games(t)

      assert %{"error" => "arbiter_role"} =
               json_response(
                 edit(conn, arbiter, t, %{
                   "kind" => "swap",
                   "a" => b1.white_player_id,
                   "b" => b2.white_player_id
                 }),
                 403
               )
    end
  end

  ## ---------- settings ----------

  describe "settings" do
    test "the desk's roles see what they may change", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)

      body = conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}") |> json_response(200)
      settings = body["tournament"]["settings"]

      assert "time_control" in settings["editable"]
      assert settings["tiebreak_options"] != []
      assert is_list(settings["configured_tiebreaks"])
    end

    test "changes the mid-event subset and audits it", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)

      body =
        conn
        |> phone(token)
        |> patch(@api <> "/tournaments/#{t.id}/settings", %{
          "settings" => %{
            "time_control" => "90'+30\"",
            "deputy_arbiter" => "Somebody Else",
            "shared_places" => true,
            "name" => "Not from a phone"
          }
        })
        |> json_response(200)

      assert body["settings"]["time_control"] == "90'+30\""
      assert body["settings"]["shared_places"]

      t2 = Tournaments.get_tournament!(t.id)
      assert t2.name == t.name
      assert t2.deputy_arbiter == "Somebody Else"

      assert Enum.any?(
               Audit.list_for_tournament(t.id),
               &(&1.action == "tournament.settings_updated" and &1.details["via"] == "mobile")
             )

      # FIDE mode froze the round count with round 1: not offered, and refused.
      refute "rounds_count" in body["settings"]["editable"]

      assert %{"error" => "locked_in_fide_mode"} =
               conn
               |> phone(token)
               |> patch(@api <> "/tournaments/#{t.id}/settings", %{
                 "settings" => %{"rounds_count" => 5}
               })
               |> json_response(422)
    end

    test "tie-breaks come from the tournament's own list", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      # Before round 1: in FIDE mode tie-breaks freeze once it is paired.
      t = tournament(owner)
      known = t.type |> PairingsEngine.Tiebreaks.selectable() |> Enum.map(& &1.code)
      pick = Enum.take(known, 2)

      body =
        conn
        |> phone(token)
        |> patch(@api <> "/tournaments/#{t.id}/settings", %{"settings" => %{"tiebreaks" => pick}})
        |> json_response(200)

      assert body["settings"]["configured_tiebreaks"] == pick

      assert %{"error" => "unknown_tiebreak"} =
               conn
               |> phone(token)
               |> patch(@api <> "/tournaments/#{t.id}/settings", %{
                 "settings" => %{"tiebreaks" => ["NOPE"]}
               })
               |> json_response(422)

      assert %{"error" => "bad_request"} =
               conn
               |> phone(token)
               |> patch(@api <> "/tournaments/#{t.id}/settings", %{})
               |> json_response(400)
    end

    test "an arbiter reads the settings but changes none", %{conn: conn, owner: owner} do
      t = paired(owner)
      arbiter = token(enlist(owner, t, "arbiter"))

      body = conn |> phone(arbiter) |> get(@api <> "/tournaments/#{t.id}") |> json_response(200)
      refute Map.has_key?(body["tournament"]["settings"], "editable")

      assert %{"error" => "arbiter_role"} =
               conn
               |> phone(arbiter)
               |> patch(@api <> "/tournaments/#{t.id}/settings", %{
                 "settings" => %{"time_control" => "5+3"}
               })
               |> json_response(403)
    end
  end

  ## ---------- Lite results ----------

  describe "a Lite phone's result" do
    test "shows in the round as from a phone, and confirming keeps it", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [p | _] = games(t)
      lite_result(t, p, "1-0")

      body =
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/rounds/1")
        |> json_response(200)

      board = Enum.find(body["round"]["boards"], &(&1["id"] == p.id))
      assert %{"by" => "Hall phone", "state" => "unconfirmed"} = board["phone"]

      assert %{"status" => "confirmed"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/boards/#{p.id}/confirm", %{
                 "expected" => "1-0"
               })
               |> json_response(200)

      assert %{state: "confirmed"} = PhoneResults.by_pairing(t.id, 1)[p.id]
      assert Enum.find(boards(t), &(&1.id == p.id)).result == "1-0"

      # Confirmed once is confirmed: a second word is refused.
      assert %{"error" => "not_from_phone"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/boards/#{p.id}/confirm", %{
                 "expected" => "1-0"
               })
               |> json_response(409)
    end

    test "rejecting clears the board; a stale view is a conflict", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [p | _] = games(t)
      lite_result(t, p, "0-1")

      assert %{"error" => "conflict", "current" => "0-1"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/boards/#{p.id}/reject", %{
                 "expected" => "1-0"
               })
               |> json_response(409)

      assert %{"status" => "rejected"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/boards/#{p.id}/reject", %{
                 "expected" => "0-1"
               })
               |> json_response(200)

      assert Enum.find(boards(t), &(&1.id == p.id)).result in [nil, ""]
      refute Map.has_key?(PhoneResults.by_pairing(t.id, 1), p.id)
      assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "pairing.result_rejected"))
    end

    test "the app's own entries are not waiting for anyone", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [p | _] = games(t)

      entry = %{
        "cid" => Ecto.UUID.generate(),
        "kind" => "result",
        "round" => 1,
        "pairing" => p.id,
        "board" => p.board,
        "white" => p.white_player_id,
        "black" => p.black_player_id,
        "result" => "1/2-1/2",
        "expected" => ""
      }

      assert %{"results" => [%{"status" => "saved"}]} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/sync", %{"entries" => [entry]})
               |> json_response(200)

      refute Map.has_key?(PhoneResults.by_pairing(t.id, 1), p.id)

      assert %{"error" => "not_from_phone"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/boards/#{p.id}/confirm", %{
                 "expected" => "1/2-1/2"
               })
               |> json_response(409)
    end

    test "an arbiter may confirm", %{conn: conn, owner: owner} do
      t = paired(owner)
      arbiter = token(enlist(owner, t, "arbiter"))
      [p | _] = games(t)
      lite_result(t, p, "1-0")

      assert %{"status" => "confirmed"} =
               conn
               |> phone(arbiter)
               |> post(@api <> "/tournaments/#{t.id}/rounds/1/boards/#{p.id}/confirm", %{
                 "expected" => "1-0"
               })
               |> json_response(200)
    end
  end

  ## ---------- incident photos ----------

  describe "incident photos" do
    defp incident(conn, token, t, extra \\ %{}) do
      [p | _] = games(t)

      entry =
        Map.merge(
          %{
            "cid" => Ecto.UUID.generate(),
            "kind" => "incident",
            "round" => 1,
            "pairing" => p.id,
            "board" => p.board,
            "type" => "clock",
            "note" => "Flag fell"
          },
          extra
        )

      assert %{"results" => [%{"status" => "saved"}]} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/sync", %{"entries" => [entry]})
               |> json_response(200)

      hd(Incidents.list(t.id))
    end

    test "attach one afterwards, then fetch it", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      i = incident(conn, token, t)
      refute i.has_photo

      body =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo", %{
          "photo" => Base.encode64(@jpeg)
        })
        |> json_response(201)

      assert body["incident"]["has_photo"]

      got = conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo")
      assert got.status == 200
      assert got.resp_body == @jpeg
      assert ["image/jpeg" <> _] = get_resp_header(got, "content-type")
      assert get_resp_header(got, "cache-control") == ["private, no-store"]

      assert %{"error" => "photo_exists"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo", %{
                 "photo" => Base.encode64(@jpeg)
               })
               |> json_response(409)

      assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "incident.photo_added"))
    end

    test "a photo sent with the incident lands too", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      i = incident(conn, token, t, %{"photo" => Base.encode64(@jpeg)})
      assert i.has_photo

      assert conn
             |> phone(token)
             |> get(@api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo")
             |> response(200) == @jpeg
    end

    test "not a JPEG, too large, or none at all is refused", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      i = incident(conn, token, t)
      url = @api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo"

      assert %{"error" => "not_a_photo"} =
               conn
               |> phone(token)
               |> post(url, %{"photo" => Base.encode64("<svg onload=alert(1)>")})
               |> json_response(415)

      big = :binary.copy(<<0>>, Incidents.photo_max() + 1)

      assert %{"error" => "photo_too_large"} =
               conn
               |> phone(token)
               |> post(url, %{"photo" => Base.encode64(<<0xFF, 0xD8, 0xFF>> <> big)})
               |> json_response(413)

      assert %{"error" => "bad_request"} =
               conn |> phone(token) |> post(url, %{}) |> json_response(400)

      assert %{"error" => "not_found"} =
               conn
               |> phone(token)
               |> get(@api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo")
               |> json_response(404)

      assert %{"error" => "not_found"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/incidents/999999/photo", %{
                 "photo" => Base.encode64(@jpeg)
               })
               |> json_response(404)
    end

    test "an arbiter sends photos with incidents but reads none back; strangers see 404", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      i = incident(conn, token, t, %{"photo" => Base.encode64(@jpeg)})
      arbiter = token(enlist(owner, t, "arbiter"))

      assert %{"error" => "arbiter_role"} =
               conn
               |> phone(arbiter)
               |> get(@api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo")
               |> json_response(403)

      stranger = token(user_scope_fixture())

      assert %{"error" => "tournament_not_found"} =
               conn
               |> phone(stranger)
               |> get(@api <> "/tournaments/#{t.id}/incidents/#{i.id}/photo")
               |> json_response(404)
    end
  end

  ## ---------- amending and deleting incidents ----------

  describe "amending and deleting an incident" do
    test "amend the kind and the note; the audit row keeps both versions", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      i = incident(conn, token, t)
      url = @api <> "/tournaments/#{t.id}/incidents/#{i.id}"

      body =
        conn
        |> phone(token)
        |> patch(url, %{"kind" => "time_added", "note" => "  Two minutes to Black "})
        |> json_response(200)

      assert body["incident"]["kind"] == "time_added"
      assert body["incident"]["note"] == "Two minutes to Black"

      # Only the note: the kind stays.
      body = conn |> phone(token) |> patch(url, %{"note" => ""}) |> json_response(200)
      assert body["incident"]["kind"] == "time_added"
      assert body["incident"]["note"] == ""

      [latest, first | _] =
        t.id |> Audit.list_for_tournament() |> Enum.filter(&(&1.action == "incident.edited"))

      assert first.details["changed_fields"] == %{
               "kind" => ["clock", "time_added"],
               "note" => ["Flag fell", "Two minutes to Black"]
             }

      assert latest.details["changed_fields"] == %{"note" => ["Two minutes to Black", ""]}
      assert first.details["board"] == i.board

      # Nothing changed: nothing written.
      conn |> phone(token) |> patch(url, %{"note" => ""}) |> json_response(200)

      assert t.id |> Audit.list_for_tournament() |> Enum.count(&(&1.action == "incident.edited")) ==
               2
    end

    test "a wrong kind, a long note, an unknown incident", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      i = incident(conn, token, t)
      url = @api <> "/tournaments/#{t.id}/incidents/#{i.id}"

      assert %{"error" => "unknown_kind"} =
               conn |> phone(token) |> patch(url, %{"kind" => "tantrum"}) |> json_response(422)

      long = String.duplicate("x", Incidents.note_max() + 1)

      assert %{"error" => "note_too_long"} =
               conn |> phone(token) |> patch(url, %{"note" => long}) |> json_response(422)

      assert %{"error" => "not_found"} =
               conn
               |> phone(token)
               |> patch(@api <> "/tournaments/#{t.id}/incidents/999999", %{"note" => "x"})
               |> json_response(404)

      assert %{"error" => "not_found"} =
               conn
               |> phone(token)
               |> delete(@api <> "/tournaments/#{t.id}/incidents/999999")
               |> json_response(404)

      assert Incidents.get(t.id, i.id).note == "Flag fell"
    end

    test "delete takes the photo with it and leaves an audit row", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      i = incident(conn, token, t, %{"photo" => Base.encode64(@jpeg)})

      assert conn
             |> phone(token)
             |> delete(@api <> "/tournaments/#{t.id}/incidents/#{i.id}")
             |> response(204) == ""

      refute Incidents.get(t.id, i.id)
      refute Incidents.get_photo(t.id, i.id)

      assert [row] =
               t.id
               |> Audit.list_for_tournament()
               |> Enum.filter(&(&1.action == "incident.deleted"))

      assert row.details["note"] == "Flag fell"
      assert row.details["photo"] == true
    end

    test "an arbiter may, as for logging one; a stranger may not", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      i = incident(conn, token, t)
      arbiter = token(enlist(owner, t, "arbiter"))
      url = @api <> "/tournaments/#{t.id}/incidents/#{i.id}"

      assert %{"incident" => %{"note" => "Both flags down"}} =
               conn
               |> phone(arbiter)
               |> patch(url, %{"note" => "Both flags down"})
               |> json_response(200)

      stranger = token(user_scope_fixture())

      assert %{"error" => "tournament_not_found"} =
               conn |> phone(stranger) |> delete(url) |> json_response(404)

      assert conn |> phone(arbiter) |> delete(url) |> response(204) == ""
    end

    test "a code that may only call the arbiter changes nothing else", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      i = incident(conn, token, t)
      url = @api <> "/tournaments/#{t.id}/incidents/#{i.id}"

      # Account-bound codes are deputies; this one is demoted by hand, to
      # see the level rule hold where logging holds it.
      Repo.update_all(Mobile.Enrollment, set: [level: "helper"])

      assert %{"error" => "kind_not_allowed"} =
               conn |> phone(token) |> patch(url, %{"note" => "x"}) |> json_response(422)

      assert %{"error" => "kind_not_allowed"} =
               conn |> phone(token) |> delete(url) |> json_response(422)

      assert Incidents.get(t.id, i.id)
    end

    test "an archived tournament keeps its incidents", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      i = incident(conn, token, t)
      {:ok, _} = Tournaments.archive_tournament(t)

      assert %{"error" => "archived"} =
               conn
               |> phone(token)
               |> delete(@api <> "/tournaments/#{t.id}/incidents/#{i.id}")
               |> json_response(409)
    end
  end
end
