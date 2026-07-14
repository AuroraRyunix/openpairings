defmodule PairingsEngineWeb.ToolsNormsLiveTest do
  # The whole point of /tools/norms is that it works for a logged-out
  # visitor and never touches the database — so unlike most LiveView tests
  # here, no register_and_log_in_user, and several tests assert row counts
  # stay frozen. async: false only because the "nothing persisted" test
  # counts absolute row totals.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Trf}
  alias PairingsEngine.Tools.Session
  alias PairingsEngine.Tournaments.{Tournament, Player}

  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  ## ---------- fixtures: fabricated TRF text (no DB, no fixture files) ----------

  # `players` is [{name, fide_id}] — one finished round between rank 1 and 2
  # when there are exactly two players, else no games (both are valid TRF).
  defp trf_text(name, players) do
    games =
      case length(players) do
        2 -> %{1 => [%{opponent_rank: 2, colour: "w", result: "1"}], 2 => [%{opponent_rank: 1, colour: "b", result: "0"}]}
        _ -> %{}
      end

    Trf.serialize(%{
      tournament: %{
        name: name,
        city: "Ghent",
        federation: "BEL",
        start_date: "2026-01-01",
        end_date: "2026-01-02",
        type: "swiss"
      },
      players:
        players
        |> Enum.with_index(1)
        |> Enum.map(fn {{pname, fide_id}, rank} ->
          %{
            rank: rank,
            name: pname,
            fide_rating: 1900,
            fide_number: fide_id,
            federation: "BEL",
            points: 0.0,
            games: Map.get(games, rank, [])
          }
        end)
    })
  end

  # One file per submit: the page supports adding files incrementally (each
  # parse appends a row), and the LiveViewTest upload client can't survive a
  # submit that consumes several entries at once — consuming the first entry
  # closes its channel, which stops the shared test UploadClient (the fake
  # transport), killing the remaining entries' channels before their turn.
  # A real socket just deletes the closed channel, so this is purely a
  # test-client limitation, not a page one.
  defp upload_files(lv, files) do
    Enum.reduce(files, "", fn {name, content}, _html ->
      input =
        file_input(lv, "#tools-upload-form", :files, [
          %{name: name, content: content, type: "application/octet-stream"}
        ])

      render_upload(input, name)
      lv |> form("#tools-upload-form", %{}) |> render_submit()
    end)
  end

  defp download_token(lv) do
    [_, token] = Regex.run(~r{/tools/download/([A-Za-z0-9_-]+)/it3}, render(lv))
    token
  end

  # The generated .xlsx is a zip; unzip in memory and join every member's
  # XML so assertions can check a filled-in value actually landed in a sheet.
  defp xlsx_xml(binary) do
    {:ok, members} = :zip.extract(binary, [:memory])
    Enum.map_join(members, fn {_name, bin} -> bin end)
  end

  ## ---------- the page itself ----------

  test "a logged-out visitor can mount /tools/norms", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/tools/norms")

    assert html =~ "Arbiter tools"
    assert html =~ "Nothing here is saved"
  end

  test "/tools redirects to /tools/norms", %{conn: conn} do
    conn = get(conn, ~p"/tools")
    assert redirected_to(conn) == ~p"/tools/norms"
  end

  test "the login page links to the arbiter tools", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")
    assert html =~ "arbiter tools"
    assert html =~ "/tools/norms"
  end

  ## ---------- upload -> parse -> download round-trip ----------

  test "uploading a TRF file lists it and IT3 downloads as a filled xlsx — with nothing persisted", %{conn: conn} do
    tournaments_before = Repo.aggregate(Tournament, :count)
    players_before = Repo.aggregate(Player, :count)

    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html = upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    assert html =~ "Alpha Open"
    # 2 players, 1 round
    assert html =~ "alpha.trf"
    assert html =~ "Download IT3"

    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["#{@xlsx_content_type}; charset=utf-8"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "IT3-alpha-open.xlsx"
    assert xlsx_xml(conn.resp_body) =~ "Alpha Open"

    assert Repo.aggregate(Tournament, :count) == tournaments_before
    assert Repo.aggregate(Player, :count) == players_before
  end

  test "officials/candidate fields flow into the downloaded FA1", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")
    upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    lv
    |> form("#tools-fields-form", %{
      "overlay" => %{"chief_arbiter_name" => "Bossuyt, Wim", "chief_arbiter_fide_id" => "200500"},
      "candidate" => %{"last_name" => "Candidate", "first_name" => "Norma", "fide_id" => "300600", "federation" => "BEL"}
    })
    |> render_change()

    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/fa1")

    assert conn.status == 200
    xml = xlsx_xml(conn.resp_body)
    assert xml =~ "Candidate"
    assert xml =~ "Norma"
    assert xml =~ "Bossuyt, Wim"
  end

  test "removing a parsed file takes it out of the report", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
      {"beta.trf", trf_text("Beta Open", [{"Carol", 333}, {"Dave", 444}])}
    ])

    assert has_element?(lv, "td", "Beta Open")

    html = render(lv)
    [_, beta_id] = Regex.run(~r{phx-value-id="(\d+)"[^>]*>\s*Remove}s, html |> String.split("beta.trf") |> Enum.at(1))

    lv |> element("button[phx-value-id=\"#{beta_id}\"]", "Remove") |> render_click()

    refute has_element?(lv, "td", "Beta Open")

    # Back to a single tournament: the IT3 filename is no longer a Festival.
    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "IT3-alpha-open.xlsx"
  end

  ## ---------- festival combining ----------

  test "two files combine into a Festival named after the master, players pooled", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html =
      upload_files(lv, [
        {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
        {"beta.trf", trf_text("Beta Open", [{"Carol", 333}, {"Dave", 444}])}
      ])

    assert html =~ "Festival"
    assert has_element?(lv, "input[type=\"radio\"][phx-value-index=\"0\"]")

    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert conn.status == 200
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "IT3-alpha-open-festival.xlsx"
    assert xlsx_xml(conn.resp_body) =~ "Alpha Open Festival"
  end

  test "picking a different master renames the Festival after it", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
      {"beta.trf", trf_text("Beta Open", [{"Carol", 333}, {"Dave", 444}])}
    ])

    lv |> element("input[type=\"radio\"][phx-value-index=\"1\"]") |> render_click()

    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "IT3-beta-open-festival.xlsx"
  end

  test "the same player in two files is a friendly duplicate error, not a 500", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
      {"beta.trf", trf_text("Beta Open", [{"Alice, Again", 111}, {"Dave", 444}])}
    ])

    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert conn.status == 200
    assert conn.resp_body =~ "can&#39;t share players"
  end

  ## ---------- hostile / stale input never 500s ----------

  test "a file that parses as neither format lists with a per-file error and blocks nothing else", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html =
      upload_files(lv, [
        {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
        {"garbage.bin", "certainly not a tournament file"}
      ])

    assert html =~ "either SWAR or TRF"
    # The good file still parsed and still downloads.
    assert html =~ "Alpha Open"

    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")
    assert conn.status == 200
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "IT3-alpha-open.xlsx"
  end

  test "an unknown token renders the friendly expired page", %{conn: conn} do
    conn = get(conn, ~p"/tools/download/no-such-token/it3")

    assert conn.status == 200
    assert conn.resp_body =~ "expired"
    assert conn.resp_body =~ "/tools/norms"
  end

  test "an expired token renders the friendly expired page", %{conn: conn} do
    token = Session.put(Session.token(), %{files: [], master_index: 0}, 0)

    conn = get(conn, ~p"/tools/download/#{token}/it3")

    assert conn.status == 200
    assert conn.resp_body =~ "expired"
  end

  test "an unknown form name renders a friendly page, not a 500", %{conn: conn} do
    conn = get(conn, ~p"/tools/download/whatever/it4")

    assert conn.status == 200
    assert conn.resp_body =~ "Unknown report"
  end

  test "a session with no successfully parsed files downloads a friendly page", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")
    upload_files(lv, [{"garbage.bin", "not a tournament file"}])

    conn = get(conn, ~p"/tools/download/#{download_token_from_session(lv)}/it3")

    assert conn.status == 200
    assert conn.resp_body =~ "upload at least one"
  end

  # No download links render when nothing parsed — pull the token straight
  # out of the LiveView's state instead.
  defp download_token_from_session(lv) do
    :sys.get_state(lv.pid).socket.assigns.token
  end

  ## ---------- upload limits ----------

  test "a file over 5 MB is rejected client-side with a friendly message", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    input =
      file_input(lv, "#tools-upload-form", :files, [
        %{
          name: "huge.trf",
          content: :binary.copy("x", 5_000_001),
          type: "application/octet-stream"
        }
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(input, "huge.trf")
    assert render(lv) =~ "File is larger than 5 MB"
  end

  test "an 11th file is rejected — 10 at a time, max", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    entries =
      for i <- 1..11 do
        %{name: "file#{i}.trf", content: "x", type: "application/octet-stream"}
      end

    input = file_input(lv, "#tools-upload-form", :files, entries)

    assert {:error, errors} = render_upload(input, "file1.trf")
    assert Enum.any?(errors, fn [_ref, reason] -> reason == :too_many_files end)
  end
end
