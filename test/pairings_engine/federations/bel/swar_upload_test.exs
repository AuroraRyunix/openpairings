defmodule PairingsEngine.Federations.BEL.SwarUploadTest do
  @moduledoc """
  What this module sends to the federation's own results site, and what
  happens when it does not land.

  Every test here goes through `Req.Test` (see `config/test.exs`'s
  `:bel_swar_upload_req_plug`) - `Req.Test` raises `"no mock or stub for
  ..."` rather than falling through to the network whenever a call reaches
  it with nothing stubbed, so a test in this file literally cannot reach
  `frbe-kbsb.be` even by forgetting to set one up. See
  `PairingsEngine.Federations.BEL.SwarUpload`'s moduledoc.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarUpload
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  defp fixture(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "SWAR Upload Test",
            "type" => "swiss",
            "rounds_count" => "1",
            "organizer" => "Test Chess Club",
            "organizer_club_number" => "351",
            "start_date" => "2026-08-01",
            "end_date" => "2026-08-01",
            "round_dates" => ["2026-08-01"]
          },
          attrs
        )
      )

    alice =
      Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice, A.", fide_rating: 2000})

    bob = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob, B.", fide_rating: 1800})
    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, date: "2026-08-01"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    Tournaments.get_tournament!(tournament.id)
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.Federations.BEL.SwarUploadTest, fun)

  defp kbsb_error(conn, messages) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(400, Jason.encode!(messages))
  end

  describe "upload/1" do
    test "PUTs the generated HTML with a Swar/ user-agent and the right content-type" do
      tournament = fixture(user_scope_fixture())

      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/sites/manager/Swar/apiTournamentUpload.php"

        assert ["Swar/" <> _version] = Plug.Conn.get_req_header(conn, "user-agent")

        assert ["text/html; charset=utf-8"] =
                 Plug.Conn.get_req_header(conn, "content-type")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ tournament.name
        assert body =~ "<meta name='Guid'"

        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:ok, updated} = SwarUpload.upload(tournament)
      assert %DateTime{} = updated.swar_uploaded_at
      assert is_binary(updated.swar_guid) and updated.swar_guid != ""

      # Persisted, not just held on the returned struct.
      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.swar_uploaded_at == updated.swar_uploaded_at
      assert reloaded.swar_guid == updated.swar_guid
      # Uploading alone must never claim the second step happened.
      assert reloaded.swar_published_at == nil
    end

    test "mints a guid first when the tournament has none yet" do
      tournament = fixture(user_scope_fixture())
      assert tournament.swar_guid in [nil, ""]

      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      assert {:ok, updated} = SwarUpload.upload(tournament)
      assert updated.swar_guid =~ ~r/^351-\d{6}-[0-9a-f]{8}-\{[0-9a-f-]{36}\}$/
    end

    test "surfaces the federation's own error array rather than a generic message" do
      tournament = fixture(user_scope_fixture())

      stub(fn conn ->
        kbsb_error(conn, [%{"message" => "meta-error", "value" => "bad Guid date"}])
      end)

      assert {:error, message} = SwarUpload.upload(tournament)
      assert message == "meta-error: bad Guid date"

      # A failed upload must not claim anything was staged.
      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.swar_uploaded_at == nil
    end

    test "joins multiple federation errors" do
      tournament = fixture(user_scope_fixture())

      stub(fn conn ->
        kbsb_error(conn, [
          %{"message" => "meta-error", "value" => "bad Guid 8 hexa"},
          %{"message" => "meta-error", "value" => "bad Guid closing char"}
        ])
      end)

      assert {:error, "meta-error: bad Guid 8 hexa; meta-error: bad Guid closing char"} =
               SwarUpload.upload(tournament)
    end

    test "a transport failure is worded plainly, not as a raw struct" do
      tournament = fixture(user_scope_fixture())
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = SwarUpload.upload(tournament)
      assert message =~ "refused"
    end

    test "an unexpected status still surfaces something readable" do
      tournament = fixture(user_scope_fixture())
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "internal error") end)

      assert {:error, message} = SwarUpload.upload(tournament)
      assert message =~ "500"
    end

    test "refuses outright for an archived tournament, without making a request" do
      tournament = fixture(user_scope_fixture())

      {:ok, tournament} =
        tournament
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()

      stub(fn _conn -> flunk("nothing should have been sent") end)

      assert {:error, message} = SwarUpload.upload(tournament)
      assert message =~ "archived"
    end
  end

  describe "index/1" do
    test "refuses when nothing has been uploaded yet" do
      tournament = fixture(user_scope_fixture())
      assert tournament.swar_guid in [nil, ""]

      stub(fn _conn -> flunk("nothing should have been sent") end)

      assert {:error, message} = SwarUpload.index(tournament)
      assert message =~ "nothing has been uploaded"
    end

    test "the guid's own curly braces reach the outgoing request intact" do
      tournament =
        fixture(user_scope_fixture(), %{
          "swar_guid" => "351-260904-a1b2c3d4-{550e8400-e29b-41d4-a716-446655440000}"
        })

      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/sites/manager/Swar/SwarTournamentUpload.php"

        # Confirmed against Req's OWN `params:` option (which runs the value
        # through `URI.encode_query/1` and percent-encodes these into
        # %7B/%7D) that the federation's script wants the literal
        # characters, the same as a real SWAR install sends - see the
        # module's moduledoc. This is the actual outgoing wire form, read
        # back the same way `Req.Test` hands every other stub its request.
        assert conn.query_string ==
                 "Guid=351-260904-a1b2c3d4-{550e8400-e29b-41d4-a716-446655440000}"

        assert conn.query_string =~ "{"
        assert conn.query_string =~ "}"
        refute conn.query_string =~ "%7B"
        refute conn.query_string =~ "%7D"

        Plug.Conn.send_resp(conn, 200, "<html>Indexed</html>")
      end)

      assert {:ok, updated} = SwarUpload.index(tournament)
      assert %DateTime{} = updated.swar_published_at
    end

    test "success persists swar_published_at" do
      tournament = fixture(user_scope_fixture())
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      {:ok, uploaded} = SwarUpload.upload(tournament)

      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "<html>OK</html>") end)
      assert {:ok, indexed} = SwarUpload.index(uploaded)

      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.swar_published_at == indexed.swar_published_at
      assert reloaded.swar_published_at != nil
    end

    test "does not try to parse the HTML confirmation page for meaning" do
      tournament = fixture(user_scope_fixture())
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      {:ok, uploaded} = SwarUpload.upload(tournament)

      stub(fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html><body>Le tournoi a été indexé.</body></html>")
      end)

      assert {:ok, _} = SwarUpload.index(uploaded)
    end

    test "surfaces the federation's error array on a failed index too" do
      tournament =
        fixture(user_scope_fixture(), %{
          "swar_guid" => "351-260904-a1b2c3d4-{550e8400-e29b-41d4-a716-446655440000}"
        })

      stub(fn conn ->
        kbsb_error(conn, [%{"message" => "meta-error", "value" => "bad Guid closing char"}])
      end)

      assert {:error, "meta-error: bad Guid closing char"} = SwarUpload.index(tournament)
    end

    test "refuses outright for a handed-off tournament, without making a request" do
      tournament =
        fixture(user_scope_fixture(), %{
          "swar_guid" => "351-260904-a1b2c3d4-{550e8400-e29b-41d4-a716-446655440000}"
        })

      {:ok, tournament} =
        tournament
        |> Ecto.Changeset.change(
          handed_off_at: DateTime.utc_now() |> DateTime.truncate(:second),
          handed_off_to: "another machine"
        )
        |> Repo.update()

      stub(fn _conn -> flunk("nothing should have been sent") end)

      assert {:error, message} = SwarUpload.index(tournament)
      assert message =~ "handed off"
    end
  end

  describe "publish/1" do
    test "both steps succeeding stamps both timestamps" do
      tournament = fixture(user_scope_fixture())

      stub(fn conn ->
        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          "GET" -> Plug.Conn.send_resp(conn, 200, "<html>OK</html>")
        end
      end)

      assert {:ok, published} = SwarUpload.publish(tournament)
      assert %DateTime{} = published.swar_uploaded_at
      assert %DateTime{} = published.swar_published_at
      refute SwarUpload.staged_but_not_indexed?(published)
    end

    test "a failed upload never attempts the index step" do
      tournament = fixture(user_scope_fixture())

      stub(fn conn ->
        case conn.method do
          "PUT" -> kbsb_error(conn, [%{"message" => "meta-error", "value" => "bad Guid date"}])
          "GET" -> flunk("index must not be attempted after a failed upload")
        end
      end)

      assert {:error, :upload, message} = SwarUpload.publish(tournament)
      assert message == "meta-error: bad Guid date"
    end

    test "upload succeeding then index failing is reported as the recoverable :index step" do
      tournament = fixture(user_scope_fixture())

      stub(fn conn ->
        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          "GET" -> Req.Test.transport_error(conn, :timeout)
        end
      end)

      assert {:error, :index, message, uploaded} = SwarUpload.publish(tournament)
      assert message =~ "timed out"
      assert %DateTime{} = uploaded.swar_uploaded_at
      assert uploaded.swar_published_at == nil
      assert SwarUpload.staged_but_not_indexed?(uploaded)

      # And it is recoverable: retrying just the index step needs no
      # re-upload, using the guid already persisted.
      stub(fn conn ->
        assert conn.method == "GET"
        Plug.Conn.send_resp(conn, 200, "<html>OK</html>")
      end)

      assert {:ok, recovered} = SwarUpload.index(uploaded)
      refute SwarUpload.staged_but_not_indexed?(recovered)
    end
  end

  describe "staged_but_not_indexed?/1" do
    test "false when nothing has ever been uploaded" do
      tournament = fixture(user_scope_fixture())
      refute SwarUpload.staged_but_not_indexed?(tournament)
    end

    test "true when uploaded and never indexed" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      tournament = fixture(user_scope_fixture())
      tournament = %{tournament | swar_uploaded_at: now, swar_published_at: nil}
      assert SwarUpload.staged_but_not_indexed?(tournament)
    end

    test "true when the most recent upload is newer than the last confirmed index" do
      published_at = DateTime.utc_now() |> DateTime.truncate(:second)
      uploaded_at = DateTime.add(published_at, 60, :second)

      tournament = fixture(user_scope_fixture())

      tournament = %{
        tournament
        | swar_uploaded_at: uploaded_at,
          swar_published_at: published_at
      }

      assert SwarUpload.staged_but_not_indexed?(tournament)
    end

    test "false when the last confirmed index is at or after the last upload" do
      uploaded_at = DateTime.utc_now() |> DateTime.truncate(:second)
      published_at = DateTime.add(uploaded_at, 5, :second)

      tournament = fixture(user_scope_fixture())

      tournament = %{
        tournament
        | swar_uploaded_at: uploaded_at,
          swar_published_at: published_at
      }

      refute SwarUpload.staged_but_not_indexed?(tournament)
    end
  end

  describe "upload_url/0 and index_url/0" do
    test "point at the federation's own upload and index scripts" do
      assert SwarUpload.upload_url() =~ "frbe-kbsb.be"
      assert SwarUpload.upload_url() =~ "apiTournamentUpload.php"
      assert SwarUpload.index_url() =~ "frbe-kbsb.be"
      assert SwarUpload.index_url() =~ "SwarTournamentUpload.php"
    end
  end
end
