defmodule PairingsEngineWeb.ToolsNormsLiveTest do
  # The whole point of /tools/norms is that it works for a logged-out
  # visitor and never touches the database - so unlike most LiveView tests
  # here, no register_and_log_in_user, and several tests assert row counts
  # stay frozen. async: false only because the "nothing persisted" test
  # counts absolute row totals.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Repo
  alias Ainalrami.Trf
  alias PairingsEngine.Tools.Session
  alias PairingsEngine.Tournaments.{Tournament, Player}

  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  ## ---------- fixtures: fabricated TRF text (no DB, no fixture files) ----------

  # `players` is [{name, fide_id}] - one finished round between rank 1 and 2
  # when there are exactly two players, else no games (both are valid TRF).
  defp trf_text(name, players) do
    games =
      case length(players) do
        2 ->
          %{
            1 => [%{opponent_rank: 2, colour: "w", result: "1"}],
            2 => [%{opponent_rank: 1, colour: "b", result: "0"}]
          }

        _ ->
          %{}
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
  # submit that consumes several entries at once - consuming the first entry
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

  # FIDE's own template requires chief arbiter's and organizer's e-mail (see
  # `report_blockers/1`'s doc) - tests that only care about some other
  # field call this first so the download isn't blocked for an unrelated
  # reason.
  # Grown beyond just e-mails as more fields joined `report_blockers/1` - kept
  # this name since every call site already means "get to a downloadable
  # state", not literally "fill only the e-mail boxes".
  defp fill_required_emails(lv) do
    lv
    |> form("#tools-fields-form", %{
      "overlay" => %{
        "chief_arbiter_email" => "chief@example.com",
        "organizer_email" => "organizer@example.com",
        "fide_tournament_id" => "12345"
      }
    })
    |> render_change()
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

  test "the arbiter tools are reachable from the top bar on the login page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")
    # The arbiter tools link lives in the top-bar "Tools" tab (no longer a
    # note on the log-in card).
    assert html =~ "/tools/norms"
  end

  ## ---------- upload -> parse -> download round-trip ----------

  test "uploading a TRF file lists it and IT3 downloads as a filled xlsx - with nothing persisted",
       %{conn: conn} do
    tournaments_before = Repo.aggregate(Tournament, :count)
    players_before = Repo.aggregate(Player, :count)

    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html =
      upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    assert html =~ "Alpha Open"
    # 2 players, 1 round
    assert html =~ "alpha.trf"
    assert html =~ "Download IT3"

    fill_required_emails(lv)
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
    Repo.insert!(%PairingsEngine.Fide.FidePlayer{
      fide_id: 200_500,
      name: "Bossuyt, Wim",
      federation: "BEL"
    })

    {:ok, lv, _html} = live(conn, ~p"/tools/norms")
    upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    # The chief arbiter FIDE id can only land in the overlay via a real pick
    # (see `PairingsEngineWeb.Components.ArbiterCombo`) - search, then pick.
    lv
    |> element("input[name='overlay[chief_arbiter_name]']")
    |> render_change(%{
      "overlay" => %{"chief_arbiter_name" => "Bossuyt"},
      "_target" => ["overlay", "chief_arbiter_name"]
    })

    lv
    |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="200500"]))
    |> render_click()

    lv
    |> form("#tools-fields-form", %{
      "candidate" => %{
        "last_name" => "Candidate",
        "first_name" => "Norma",
        "fide_id" => "300600",
        "federation" => "BEL"
      }
    })
    |> render_change()

    fill_required_emails(lv)
    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/fa1")

    assert conn.status == 200
    xml = xlsx_xml(conn.resp_body)
    # Surname in capitals is FIDE house style on these forms (see
    # `Norms.Forms.fide_display_name/1`); the given name keeps its casing.
    # The chief arbiter's name (FA1 B18) gets the same treatment.
    assert xml =~ "CANDIDATE"
    assert xml =~ "Norma"
    assert xml =~ "BOSSUYT, Wim"
  end

  test "organizer and chief arbiter e-mails flow into the downloaded IT3", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")
    upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    lv
    |> form("#tools-fields-form", %{
      "overlay" => %{
        "chief_arbiter_email" => "chief@example.com",
        "organizer_email" => "organizer@example.com",
        "fide_tournament_id" => "12345"
      }
    })
    |> render_change()

    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert conn.status == 200
    xml = xlsx_xml(conn.resp_body)
    assert xml =~ "chief@example.com"
    assert xml =~ "organizer@example.com"
    # Generated from the public Tools page, so Program used credits SWAR
    # rather than OpenPairings (see Norms.Forms.it3_fills/3).
    assert xml =~ "Swar (With JaVaFo)"
  end

  test "no FIDE tournament ID blocks the downloads, even with every official filled in", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")
    upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    lv
    |> form("#tools-fields-form", %{
      "overlay" => %{
        "chief_arbiter_email" => "chief@example.com",
        "organizer_email" => "organizer@example.com"
      }
    })
    |> render_change()

    html = render(lv)
    assert html =~ "Not ready to submit to FIDE"
    assert html =~ "FIDE tournament ID"
    refute html =~ ~s(href="/tools/download/)

    html =
      lv
      |> form("#tools-fields-form", %{"overlay" => %{"fide_tournament_id" => "12345"}})
      |> render_change()

    refute html =~ "Not ready to submit to FIDE"
    assert html =~ ~s(href="/tools/download/)
  end

  test "only 2 ranked deputy arbiter slots are offered - FIDE never ranks a 3rd/4th",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html =
      upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    assert html =~ "Deputy 1"
    assert html =~ "Deputy 2"
    refute html =~ "Deputy 3"
    refute html =~ "Deputy 4"
  end

  test "the IT3 counts explainer shows the uploaded players' breakdown, open by default", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html =
      upload_files(lv, [
        {"alpha.trf",
         trf_text("Alpha Open", [{"Carlsen, Magnus", 1_503_014}, {"Nakamura, Hikaru", 2_016_192}])}
      ])

    assert html =~ "How the IT3 rated / titled / federation counts were calculated"
    assert html =~ ~s(class="it3-explain" open)
    assert html =~ "Carlsen, Magnus"
    assert html =~ "Nakamura, Hikaru"
  end

  test "the '+ Add arbiter' button offers a 5th slot beyond the 4 built-in deputies, which flows into the download",
       %{conn: conn} do
    Repo.insert!(%PairingsEngine.Fide.FidePlayer{
      fide_id: 205_494,
      name: "Cornet, Luc",
      federation: "BEL"
    })

    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html =
      upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    refute html =~ "Arbiter 1"

    html = lv |> element(~s(button[phx-click="add_arbiter"])) |> render_click()

    assert html =~ "Arbiter 1"

    lv
    |> element("input[name='overlay[arbiter1_name]']")
    |> render_change(%{
      "overlay" => %{"arbiter1_name" => "Cornet"},
      "_target" => ["overlay", "arbiter1_name"]
    })

    lv
    |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="205494"]))
    |> render_click()

    fill_required_emails(lv)
    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert conn.status == 200
    xml = xlsx_xml(conn.resp_body)
    assert xml =~ "205494"
    assert xml =~ "CORNET, Luc"
  end

  # Verified by tracing `Combine.combine/2` in the LiveView process itself
  # (rather than a wall-clock measurement, which would be flaky): the counts
  # explainer used to be recomputed from the template, so every keystroke in
  # an officials box recombined every uploaded file and re-walked the pooled
  # roster.
  test "typing in an officials box does not recombine the uploaded files", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
      {"beta.trf", trf_text("Beta Open", [{"Carol", 333}, {"Dave", 444}])}
    ])

    :erlang.trace(lv.pid, true, [:call])
    :erlang.trace_pattern({PairingsEngine.Norms.Combine, :combine, 2}, true, [:global])

    on_exit(fn ->
      :erlang.trace_pattern({PairingsEngine.Norms.Combine, :combine, 2}, false, [])
    end)

    # A keystroke: the explainer's inputs (files, master index) are untouched.
    lv
    |> form("#tools-fields-form", %{"overlay" => %{"chief_arbiter_email" => "a@example.com"}})
    |> render_change()

    refute_received {:trace, _, :call, {PairingsEngine.Norms.Combine, :combine, _}}

    # Positive control: changing the master file does recompute it.
    render_click(lv, "set_master", %{"index" => "1"})

    assert_received {:trace, _, :call, {PairingsEngine.Norms.Combine, :combine, _}}
  end

  test "a non-numeric or out-of-range master index leaves the socket alive", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
      {"beta.trf", trf_text("Beta Open", [{"Carol", 333}, {"Dave", 444}])}
    ])

    assert render_click(lv, "set_master", %{"index" => "not-a-number"}) =~ "Alpha Open"
    assert render_click(lv, "set_master", %{"index" => "99"}) =~ "Alpha Open"
    assert render_click(lv, "set_master", %{"index" => "-3"}) =~ "Alpha Open"
    assert render_click(lv, "set_master", %{}) =~ "Alpha Open"

    # And the download - which is where the unclamped index used to land -
    # still works.
    fill_required_emails(lv)
    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")
    assert conn.status == 200
  end

  test "a crafted extra_arbiters_count is clamped to the maximum", %{conn: conn} do
    max = PairingsEngine.Norms.Forms.max_extra_arbiters()

    {:ok, lv, _html} = live(conn, ~p"/tools/norms")
    upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    # Straight at the event: the count is never rendered as an input on this
    # page (it's driven by "+ Add arbiter"), so the only way to set it is a
    # crafted `update_fields` payload - which is exactly the finding.
    html =
      render_change(lv, "update_fields", %{"overlay" => %{"extra_arbiters_count" => "100000000"}})

    # The rendered boxes stop at the cap ...
    assert html =~ "Arbiter #{max}"
    refute html =~ "Arbiter #{max + 1}"

    # ... and so does what the download route reads back out of the session.
    fill_required_emails(lv)
    {:ok, session} = Session.get(download_token(lv))
    assert session.overlay["extra_arbiters_count"] == max
  end

  test "five extra arbiters still work end to end", %{conn: conn} do
    Repo.insert!(%PairingsEngine.Fide.FidePlayer{
      fide_id: 205_494,
      name: "Cornet, Luc",
      federation: "BEL"
    })

    {:ok, lv, _html} = live(conn, ~p"/tools/norms")
    upload_files(lv, [{"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

    html =
      Enum.reduce(1..5, "", fn _, _ ->
        lv |> element(~s(button[phx-click="add_arbiter"])) |> render_click()
      end)

    assert html =~ "Arbiter 5"

    lv
    |> element("input[name='overlay[arbiter5_name]']")
    |> render_change(%{
      "overlay" => %{"arbiter5_name" => "Cornet"},
      "_target" => ["overlay", "arbiter5_name"]
    })

    lv
    |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="205494"]))
    |> render_click()

    fill_required_emails(lv)
    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert conn.status == 200
    xml = xlsx_xml(conn.resp_body)
    assert xml =~ "205494"
    assert xml =~ "CORNET, Luc"
  end

  test "removing a parsed file takes it out of the report", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
      {"beta.trf", trf_text("Beta Open", [{"Carol", 333}, {"Dave", 444}])}
    ])

    assert has_element?(lv, "td", "Beta Open")

    html = render(lv)

    [_, beta_id] =
      Regex.run(
        ~r{phx-value-id="(\d+)"[^>]*>\s*Remove}s,
        html |> String.split("beta.trf") |> Enum.at(1)
      )

    lv |> element("button[phx-value-id=\"#{beta_id}\"]", "Remove") |> render_click()

    refute has_element?(lv, "td", "Beta Open")

    # Back to a single tournament: the IT3 filename is no longer a Festival.
    fill_required_emails(lv)
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

    fill_required_emails(lv)
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

    fill_required_emails(lv)
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

    fill_required_emails(lv)
    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

    assert conn.status == 200
    assert conn.resp_body =~ "can&#39;t share players"
  end

  ## ---------- hostile / stale input never 500s ----------

  test "a file that parses as neither format lists with a per-file error and blocks nothing else",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    html =
      upload_files(lv, [
        {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
        {"garbage.bin", "certainly not a tournament file"}
      ])

    assert html =~ "either SWAR or TRF"
    # The good file still parsed and still downloads.
    assert html =~ "Alpha Open"

    fill_required_emails(lv)
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

  # No download links render when nothing parsed - pull the token straight
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

  test "an 11th file is rejected - 10 at a time, max", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    entries =
      for i <- 1..11 do
        %{name: "file#{i}.trf", content: "x", type: "application/octet-stream"}
      end

    input = file_input(lv, "#tools-upload-form", :files, entries)

    assert {:error, errors} = render_upload(input, "file1.trf")
    assert Enum.any?(errors, fn [_ref, reason] -> reason == :too_many_files end)
  end

  ## ---------- junk footer removed ----------

  test "the promotional footer is gone", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/tools/norms")
    refute html =~ "the full free tournament manager these forms come from"
  end

  ## ---------- officials prefilled from the master file ----------

  test "uploading a file prefills the chief arbiter from it, without clobbering manual edits", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    trf =
      Trf.serialize(%{
        tournament: %{
          name: "Alpha Open",
          city: "Ghent",
          federation: "BEL",
          start_date: "2026-01-01",
          end_date: "2026-01-02",
          type: "swiss",
          chief_arbiter: "Bossuyt, Wim"
        },
        players: [
          %{
            rank: 1,
            name: "Alice",
            fide_rating: 1900,
            fide_number: 111,
            federation: "BEL",
            points: 0.0,
            games: []
          }
        ]
      })

    html = upload_files(lv, [{"alpha.trf", trf}])

    assert html =~ "Bossuyt, Wim"

    # Manually overwrite the chief arbiter, then upload a second file whose
    # own chief arbiter differs - the manual edit must survive.
    lv
    |> form("#tools-fields-form", %{"overlay" => %{"chief_arbiter_name" => "Someone Else"}})
    |> render_change()

    trf2 =
      Trf.serialize(%{
        tournament: %{
          name: "Beta Open",
          city: "Ghent",
          federation: "BEL",
          start_date: "2026-01-01",
          end_date: "2026-01-02",
          type: "swiss",
          chief_arbiter: "Different Arbiter"
        },
        players: [
          %{
            rank: 1,
            name: "Carol",
            fide_rating: 1900,
            fide_number: 333,
            federation: "BEL",
            points: 0.0,
            games: []
          }
        ]
      })

    html2 = upload_files(lv, [{"beta.trf", trf2}])

    assert html2 =~ "Someone Else"
    refute html2 =~ "Different Arbiter"
  end

  test "each deputy prefills into their own box, not one string dumped into deputy1", %{
    conn: conn
  } do
    Repo.insert!(%PairingsEngine.Fide.FidePlayer{
      fide_id: 100_100,
      name: "De Vet, Sylvin",
      federation: "BEL"
    })

    Repo.insert!(%PairingsEngine.Fide.FidePlayer{
      fide_id: 100_200,
      name: "Van Dyck, Marc",
      federation: "BEL"
    })

    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    trf =
      Trf.serialize(%{
        tournament: %{
          name: "Alpha Open",
          city: "Ghent",
          federation: "BEL",
          start_date: "2026-01-01",
          end_date: "2026-01-02",
          type: "swiss",
          chief_arbiter: "Cornet, Luc",
          deputy_arbiters: ["De Vet, Sylvin", "Van Dyck, Marc"]
        },
        players: [
          %{
            rank: 1,
            name: "Alice",
            fide_rating: 1900,
            fide_number: 111,
            federation: "BEL",
            points: 0.0,
            games: []
          }
        ]
      })

    html = upload_files(lv, [{"alpha.trf", trf}])

    # Each name lands in its own box, AND - since both resolve to exactly one
    # FIDE entry - the matching FIDE ID comes along too (see
    # `SwarImport.match_official_fide_player/1`), same as picking each by
    # hand from the combobox would.
    assert html =~
             ~s(name="overlay[deputy1_name]" value="De Vet, Sylvin")

    assert html =~
             ~s(name="overlay[deputy2_name]" value="Van Dyck, Marc")

    assert html =~ ~s(name="overlay[deputy1_fide_id]" value="100100")
    assert html =~ ~s(name="overlay[deputy2_fide_id]" value="100200")
  end

  test "a deputy name with no confident FIDE match is left blank, with a hint showing what the file said",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    trf =
      Trf.serialize(%{
        tournament: %{
          name: "Alpha Open",
          city: "Ghent",
          federation: "BEL",
          start_date: "2026-01-01",
          end_date: "2026-01-02",
          type: "swiss",
          chief_arbiter: "Cornet, Luc",
          deputy_arbiters: ["Someone Unmatched"]
        },
        players: [
          %{
            rank: 1,
            name: "Alice",
            fide_rating: 1900,
            fide_number: 111,
            federation: "BEL",
            points: 0.0,
            games: []
          }
        ]
      })

    html = upload_files(lv, [{"alpha.trf", trf}])

    # No FIDE entry to match against - the box stays empty (never a raw,
    # unverified name silently sitting where only a FIDE-confirmed one
    # should), but the hint says what the file did carry.
    assert html =~ ~s(name="overlay[deputy1_name]" value="")
    assert html =~ ~s(name="overlay[deputy1_fide_id]" value="")
    assert html =~ "Uploaded file says: Someone Unmatched"
  end

  ## ---------- uploaded-files totals ----------

  test "the uploaded-files table shows per-file titled/federation counts and totals", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    trf =
      Trf.serialize(%{
        tournament: %{
          name: "Alpha Open",
          city: "Ghent",
          federation: "BEL",
          start_date: "2026-01-01",
          end_date: "2026-01-02",
          type: "swiss"
        },
        players: [
          %{
            rank: 1,
            name: "Alice",
            title: "IM",
            fide_rating: 1900,
            fide_number: 111,
            federation: "BEL",
            points: 0.0,
            games: []
          },
          %{
            rank: 2,
            name: "Bob",
            fide_rating: 1800,
            fide_number: 222,
            federation: "NED",
            points: 0.0,
            games: []
          }
        ]
      })

    html = upload_files(lv, [{"alpha.trf", trf}])

    assert html =~ "Titled"
    assert html =~ "Feds"
    assert html =~ "2 players, 1 titled"
    assert html =~ "2 distinct federations"
    assert html =~ "No federation appears in more than one uploaded file."
  end

  test "federations shared across files are surfaced as a hint", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"alpha.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])},
      {"beta.trf", trf_text("Beta Open", [{"Carol", 333}, {"Dave", 444}])}
    ])

    html = render(lv)
    assert html =~ "Federations shared across files: BEL."
  end

  ## ---------- pure helpers ----------

  describe "collapse_event_codes/1" do
    alias PairingsEngineWeb.ToolsNormsLive

    test "a single code is returned as-is" do
      assert ToolsNormsLive.collapse_event_codes(["10001"]) == "10001"
    end

    test "consecutive codes collapse into one range" do
      assert ToolsNormsLive.collapse_event_codes(["10001", "10002", "10003"]) == "10001-10003"
    end

    test "a gap splits into a bare code and a range" do
      assert ToolsNormsLive.collapse_event_codes(["10001", "10003", "10004"]) ==
               "10001, 10003-10004"
    end

    test "unordered/duplicate input is sorted and de-duplicated first" do
      assert ToolsNormsLive.collapse_event_codes(["10003", "10001", "10002", "10001"]) ==
               "10001-10003"
    end

    test "blanks are dropped and an empty list yields an empty string" do
      assert ToolsNormsLive.collapse_event_codes(["", "10001", " "]) == "10001"
      assert ToolsNormsLive.collapse_event_codes([]) == ""
    end
  end

  describe "uploaded-files totals helpers" do
    alias PairingsEngineWeb.ToolsNormsLive

    defp file_row(players) do
      %{error: nil, tournament: %Tournament{}, players: players}
    end

    defp player(attrs), do: struct(PairingsEngine.Tournaments.Player, attrs)

    test "total_players/1, total_titled_players/1 and total_federations/1 sum across successful files" do
      files = [
        file_row([player(title: "IM", federation: "BEL"), player(federation: "NED")]),
        file_row([player(title: "", federation: "BEL"), player(title: "WFM", federation: "FRA")]),
        %{error: "bad file", tournament: nil, players: nil}
      ]

      assert ToolsNormsLive.total_players(files) == 4
      assert ToolsNormsLive.total_titled_players(files) == 2
      assert ToolsNormsLive.total_federations(files) == 3
    end

    test "shared_federations/1 lists federations appearing in 2+ files" do
      files = [
        file_row([player(federation: "BEL"), player(federation: "NED")]),
        file_row([player(federation: "BEL"), player(federation: "FRA")]),
        file_row([player(federation: "NED")])
      ]

      assert ToolsNormsLive.shared_federations(files) == ["BEL", "NED"]
    end

    test "shared_federations/1 is empty for a single file" do
      files = [file_row([player(federation: "BEL")])]
      assert ToolsNormsLive.shared_federations(files) == []
    end
  end

  ## ---------- FIDE lookup parity with the signed-in Norms page ----------

  describe "arbiter FIDE lookup on the public tools page" do
    setup do
      Repo.insert_all(PairingsEngine.Fide.FidePlayer, [
        %{fide_id: 207_640, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1960},
        %{fide_id: 228_494, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1953},
        %{fide_id: 214_787, name: "De Vet, Sylvin", federation: "BEL", birth_year: 1947}
      ])

      :ok
    end

    test "typing a name searches and distinguishes namesakes, no button needed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/tools/norms")
      # The officials form only renders once a file has been parsed.
      upload_files(lv, [{"a.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

      # Typing in the box itself searches - target the input directly since a
      # real browser routes the change event to the input's OWN phx-change,
      # not the surrounding form's `update_fields`.
      html =
        lv
        |> element("input[name='overlay[deputy1_name]']")
        |> render_change(%{
          "overlay" => %{"deputy1_name" => "Van Dyck"},
          "_target" => ["overlay", "deputy1_name"]
        })

      # Birth year + id, because "Van Dyck, Marc · BEL" twice is unpickable.
      assert html =~ "b. 1960"
      assert html =~ "b. 1953"
      assert html =~ "#207640"
    end

    test "picking a result fills BOTH the name and the FIDE ID", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/tools/norms")
      # The officials form only renders once a file has been parsed.
      upload_files(lv, [{"a.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

      lv
      |> element("input[name='overlay[deputy1_name]']")
      |> render_change(%{
        "overlay" => %{"deputy1_name" => "De Vet"},
        "_target" => ["overlay", "deputy1_name"]
      })

      html =
        lv
        |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="214787"]))
        |> render_click()

      assert html =~ ~s(value="De Vet, Sylvin")
      assert html =~ ~s(value="214787")
    end

    test "the candidate picker fills all four fields from the chosen official", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/tools/norms")
      # The officials form only renders once a file has been parsed.
      upload_files(lv, [{"a.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

      # A FIDE id can only ever land in the overlay via an actual pick - see
      # `PairingsEngineWeb.Components.ArbiterCombo` - so search then pick,
      # same as the "picking a result" test above.
      lv
      |> element("input[name='overlay[deputy1_name]']")
      |> render_change(%{
        "overlay" => %{"deputy1_name" => "De Vet"},
        "_target" => ["overlay", "deputy1_name"]
      })

      lv
      |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="214787"]))
      |> render_click()

      html =
        lv
        |> element(~s(select[name="pick"]))
        |> render_change(%{"pick" => "deputy1"})

      # FIDE's record drives the split, so the multi-word surname survives.
      assert html =~ ~s(value="De Vet")
      assert html =~ ~s(value="Sylvin")
      assert html =~ ~s(value="BEL")
    end

    test "no candidate picker until an official has been named", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/tools/norms")

      html =
        upload_files(lv, [{"a.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

      # The form is on screen, but no official is named yet, so nothing to pick.
      assert html =~ "tools-fields-form"
      refute html =~ "Pick an arbiter"
    end

    test "organizer has the same real FIDE-lookup combobox as the other officials, and it flows into the downloaded IT3",
         %{conn: conn} do
      Repo.insert!(%PairingsEngine.Fide.FidePlayer{
        fide_id: 300_100,
        name: "Burssens, Jorian",
        federation: "BEL"
      })

      {:ok, lv, html} = live(conn, ~p"/tools/norms")
      upload_files(lv, [{"a.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

      refute html =~ "Organizer FIDE ID"
      assert has_element?(lv, "input[name='overlay[organizer_name]']")

      lv
      |> element("input[name='overlay[organizer_name]']")
      |> render_change(%{
        "overlay" => %{"organizer_name" => "Burssens"},
        "_target" => ["overlay", "organizer_name"]
      })

      html =
        lv
        |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="300100"]))
        |> render_click()

      assert html =~ ~s(value="Burssens, Jorian")
      assert html =~ ~s(value="300100")

      fill_required_emails(lv)
      conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

      assert conn.status == 200
      xml = xlsx_xml(conn.resp_body)
      assert xml =~ "300100"
      assert xml =~ "BURSSENS, Jorian"
    end

    test "person responsible for pairings has the same real FIDE-lookup combobox, and it flows into the downloaded IT3",
         %{conn: conn} do
      Repo.insert!(%PairingsEngine.Fide.FidePlayer{
        fide_id: 500_200,
        name: "Devet, Sylvin",
        federation: "BEL"
      })

      {:ok, lv, _html} = live(conn, ~p"/tools/norms")
      upload_files(lv, [{"a.trf", trf_text("Alpha Open", [{"Alice", 111}, {"Bob", 222}])}])

      assert has_element?(lv, "input[name='overlay[person_responsible_pairings]']")

      lv
      |> element("input[name='overlay[person_responsible_pairings]']")
      |> render_change(%{
        "overlay" => %{"person_responsible_pairings" => "Devet"},
        "_target" => ["overlay", "person_responsible_pairings"]
      })

      html =
        lv
        |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="500200"]))
        |> render_click()

      assert html =~ ~s(value="Devet, Sylvin")
      assert html =~ ~s(value="500200")

      fill_required_emails(lv)
      conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")

      assert conn.status == 200
      xml = xlsx_xml(conn.resp_body)
      assert xml =~ "DEVET, Sylvin"
    end
  end

  test "player surnames are capitalised in the downloaded IT4", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/tools/norms")

    upload_files(lv, [
      {"a.trf", trf_text("Alpha Open", [{"Burssens, Jorian", 111}, {"Bob", 222}])}
    ])

    fill_required_emails(lv)
    conn = get(conn, ~p"/tools/download/#{download_token(lv)}/it3")
    assert conn.status == 200
  end

  ## ---------- titled counts agree with the generated form ----------

  # The uploaded-file table used to count any non-blank title, while the
  # generated FA1/IA1 excluded CM/WCM - so the screen said 14 and the form said
  # 9 for the same tournament. Both now go through `Forms.titled?/1`.

  ## ---------- titled counts agree with the generated form ----------

  # The uploaded-file table used to count any non-blank title while the
  # generated FA1/IA1 excluded CM/WCM - so the screen said 14 and the form said
  # 9 for the same tournament. Both now go through `Forms.titled?/1`.
  describe "titled counts exclude CM/WCM" do
    alias PairingsEngineWeb.ToolsNormsLive

    test "CM and WCM don't count towards the uploaded-file total" do
      files = [
        file_row([
          player(title: "GM"),
          player(title: "IM"),
          player(title: "FM"),
          player(title: "CM"),
          player(title: "WCM"),
          player(title: "")
        ])
      ]

      # Five players carry a title string; only three are FIDE-titled.
      assert ToolsNormsLive.total_titled_players(files) == 3
    end

    test "the table total agrees with the FA1 form's own count" do
      players =
        Enum.map(~w(GM IM FM FM CM CM CM), fn t -> player(title: t) end)

      row = file_row(players)

      from_form =
        PairingsEngine.Norms.Forms.fa1_fills(row.tournament, row.players, %{})["Invulformulier"][
          "B16"
        ]

      assert ToolsNormsLive.total_titled_players([row]) == from_form
      assert from_form == 4
    end
  end
end
