defmodule PairingsEngineWeb.ExportController do
  @moduledoc """
  Downloads for tournament data: FIDE TRF16 (`PairingsEngine.TrfExport`) and
  full-fidelity JSON backups (`PairingsEngine.TournamentExport`). See
  `docs/import-export.md`. JSON *import* isn't here - a file upload can't be
  a plain GET download route - see the "Import backup" control on
  `PairingsEngineWeb.TournamentsLive`, backed by
  `PairingsEngine.TournamentImport`.

  Every single-tournament action scopes the tournament through
  `Tournaments.get_authorized_tournament!/2`, so a tournament id the
  current user doesn't own and isn't a collaborator on 404s the same way
  the rest of the app does.

  ## The two POSTs

  `hand_off/2` and `hand_off_return/2` are the only actions here that change
  anything, and they are POSTs because of it: both LOCK the tournament on
  their way to producing the file (see `PairingsEngine.Handoff`), and a GET
  that locks a tournament would be fired by a link prefetch or a browser
  restoring tabs.

  They live in a controller rather than in `PairingsEngineWeb.TournamentsLive`
  for the same reason the import does not live here: a LiveView cannot hand
  the browser a file. The forms that drive them are on that LiveView and post
  across.
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{
    Handoff,
    PgnExport,
    TournamentExport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Features
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarPublish}

  @doc """
  GET /t/:id/export/trf?rounds=1-5 - TRF16 text download, all or selected
  rounds. Filename convention: `<X>_<fideid>_<slug>_<rounds>.trf`, where
  `<X>` is B/R/S for `tournament.standard` (blitz/rapid/standard), `<fideid>`
  is whichever FIDE tournament ID `TrfExport.applicable_fide_id/2` resolves
  for the exported round range (segment omitted when none applies), `<slug>`
  is the same sanitized tournament-name slug every other export filename
  uses (see `filename/2`), and `<rounds>` is a compact descriptor of the
  exported round span (e.g. `r1-5`, `r1-3+8`, or `all`). See
  `trf_filename/2`.
  """
  def trf(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)

    case TrfExport.export(tournament, params["rounds"]) do
      {:ok, text} ->
        meta = TrfExport.export_meta(tournament, params["rounds"])

        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{trf_filename(tournament, meta)}\""
        )
        |> send_resp(200, text)

      {:error, %Ainalrami.Trf.ValidationError{message: message}} ->
        conn
        |> put_flash(:error, "Could not export TRF: #{message}")
        |> redirect(to: ~p"/t/#{tournament.id}/pairings")
    end
  end

  @doc """
  GET /t/:id/export/pgn?round=N&board=1 - metadata-only PGN text download,
  one round or all rounds. `board=1` adds a [Board "N"] tag to every game
  (see `PgnExport.export/3`'s moduledoc); omitted/anything else leaves it
  off, matching the export's long-standing default.
  """
  def pgn(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    round_number = parse_round_param(params["round"])
    text = PgnExport.export(tournament, round_number, board: params["board"] == "1")

    conn
    |> put_resp_content_type("application/x-chess-pgn")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"#{filename(tournament, "pgn")}\""
    )
    |> send_resp(200, text)
  end

  defp parse_round_param(nil), do: nil
  defp parse_round_param(""), do: nil

  defp parse_round_param(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc """
  GET /t/:id/export/swar - a `.swar` v7 binary SWAR itself can open. See
  `PairingsEngine.Federations.BEL.SwarExport`'s moduledoc for exactly what this can and
  cannot round-trip, and why it has never been verified against a real
  SWAR install.
  """
  def swar(conn, %{"id" => id}) do
    # Checked here as well as on the Export settings page that links to it.
    # The page decides what is offered; a URL is typed, bookmarked and
    # shared, so the route has to hold its own. `:forbidden` rather than
    # `:not_found`: the tournament exists and is theirs, and the honest
    # answer is that this download is switched off, not that it is missing.
    #
    # Nothing about the tournament changes either way - `SwarExport` reads,
    # and never writes. See `PairingsEngine.Features`.
    if Features.enabled?(conn.assigns.current_scope, "bel_swar_export") do
      tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
      binary = SwarExport.export(tournament.id)

      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{filename(tournament, "swar")}\""
      )
      |> send_resp(200, binary)
    else
      conn
      |> put_status(:forbidden)
      |> put_view(html: PairingsEngineWeb.ErrorHTML)
      |> text(gettext("SWAR export is switched off for your account. Turn it on under Features."))
    end
  end

  @doc """
  GET /t/:id/export/swar_html - a SWAR-compatible HTML results page: the
  head, banner, standings and per-round results the federation's results
  site expects. See `PairingsEngine.Federations.BEL.SwarPublish`'s
  moduledoc for exactly what it covers and what it deliberately leaves
  out. Download only - this route never uploads anything anywhere.
  """
  def swar_html(conn, %{"id" => id}) do
    # Same shape as `swar/2` above: checked here as well as on the Export
    # settings page that links to it, since a URL is typed, bookmarked and
    # shared and the route has to hold its own either way.
    if Features.enabled?(conn.assigns.current_scope, "bel_swar_publish") do
      tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
      # `ensure_guid!/1` first, not just inside `export/1`: the filename and
      # the document's own `Guid` meta tag both have to agree on the same
      # (possibly freshly-generated, possibly freshly-persisted) guid.
      tournament = SwarPublish.ensure_guid!(tournament)
      html = SwarPublish.export(tournament)

      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{SwarPublish.filename(tournament)}\""
      )
      |> send_resp(200, html)
    else
      conn
      |> put_status(:forbidden)
      |> put_view(html: PairingsEngineWeb.ErrorHTML)
      |> text(
        gettext(
          "The SWAR results page is switched off for your account. Turn it on under Features."
        )
      )
    end
  end

  @doc "GET /t/:id/export/json - full-fidelity JSON backup of one tournament."
  def json(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    envelope = TournamentExport.export_tournament(tournament)

    send_json_download(conn, envelope, filename(tournament, "json"))
  end

  @doc "GET /export/tournaments.json - full-fidelity JSON backup of every tournament the current user can access (owned or collaborated)."
  def all_json(conn, _params) do
    envelope = TournamentExport.export_all(conn.assigns.current_scope)

    send_json_download(
      conn,
      envelope,
      "openpairings-export-#{Date.to_iso8601(Date.utc_today())}.json"
    )
  end

  @doc """
  POST /t/:id/export/handoff - hands the tournament over to another copy of
  the app and downloads the file that makes it live there.

  A download that changes state, which is why it is a POST and why it is here
  rather than in `PairingsEngineWeb.TournamentsLive`: a LiveView cannot hand
  the browser a file, and the two halves of a hand-off (lock, then file) must
  not be separable by a failed request. `PairingsEngine.Handoff.hand_off/3`
  does both in one transaction; this either sends the result or redirects with
  the reason, having locked nothing.

  The submitted `to` is the free-text destination an arbiter typed. It is not
  validated against anything - see the migration's note on `handed_off_to` -
  beyond being non-blank, which the context enforces.
  """
  def hand_off(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    tournament = Tournaments.get_authorized_tournament!(scope, id)

    case Handoff.hand_off(tournament, to_label(params), scope) do
      {:ok, payload} ->
        send_json_download(conn, payload, handoff_filename(tournament, "handoff"))

      {:error, reason} ->
        refuse(conn, handoff_error(reason))
    end
  end

  @doc """
  POST /t/:id/export/handoff/return - gives a received tournament back, and
  downloads the file that unlocks the copy it came from.

  The mirror of `hand_off/2` and a POST for the same reason: it locks this
  copy. No destination is asked for - a return goes back where it came from,
  which `PairingsEngine.Handoff.return/2` reads off the row.
  """
  def hand_off_return(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    tournament = Tournaments.get_authorized_tournament!(scope, id)

    case Handoff.return(tournament, scope) do
      {:ok, payload} ->
        send_json_download(conn, payload, handoff_filename(tournament, "return"))

      {:error, reason} ->
        refuse(conn, handoff_error(reason))
    end
  end

  defp to_label(params) do
    case params do
      %{"handoff" => %{"to" => to}} when is_binary(to) -> to
      %{"to" => to} when is_binary(to) -> to
      _ -> ""
    end
  end

  # Back to the list rather than to the tournament: a refused hand-off leaves
  # the arbiter deciding what to do about the tournament as a whole, and the
  # list is where every other whole-tournament action lives.
  defp refuse(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/")
  end

  # `PairingsEngine.Handoff` answers in atoms so the wording lives with the
  # screen rather than with the context - the same split every other refusal
  # in this app uses.
  defp handoff_error(:no_destination),
    do:
      gettext(
        "Say where the tournament is going first - the copy left behind can only tell people what you type here."
      )

  defp handoff_error(:already_handed_off),
    do:
      gettext(
        "This tournament has already been handed off. Take it back before handing it somewhere else."
      )

  defp handoff_error(:archived),
    do: gettext("This tournament is archived - unarchive it before handing it off.")

  defp handoff_error(:not_received),
    do:
      gettext(
        "This tournament wasn't handed to this machine, so there is nothing to give back. Hand it off instead."
      )

  defp handoff_error(message) when is_binary(message), do: message

  defp handoff_error(other),
    do: gettext("Could not hand this tournament over: %{reason}", reason: inspect(other))

  # `<slug>-handoff.json` / `<slug>-return.json`. The kind is in the name
  # because both files look identical in a downloads folder and only one of
  # them unlocks anything - and an arbiter with two of these open is exactly
  # the situation where picking the wrong one costs an evening.
  defp handoff_filename(tournament, kind), do: "#{tournament_slug(tournament)}-#{kind}.json"

  defp send_json_download(conn, envelope, filename) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, Jason.encode!(envelope))
  end

  defp filename(tournament, ext) do
    "#{tournament_slug(tournament)}.#{ext}"
  end

  # The character class is ASCII-only, so a name written entirely in a
  # non-Latin script ("大会", "Турнир") reduced to "" and the download came
  # out named ".trf" / ".json" - a dotfile with no stem, which some browsers
  # and file managers hide outright. Fall back to the tournament's id, which
  # always yields a usable, unique-per-tournament filename.
  defp tournament_slug(tournament) do
    slug =
      (tournament.name || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: "tournament-#{tournament.id}", else: slug
  end

  # `<X>_<fideid>_<slug>_<rounds>.trf` - see the `trf/2` moduledoc above.
  # `.trf` (not the ".txt" a user might informally expect) matches this
  # project's established TRF export extension - every other TRF surface
  # (this controller's previous filename, `docs/import-export.md`) already
  # uses `.trf`, so this keeps that consistent rather than introducing a
  # second convention.
  defp trf_filename(tournament, %{rounds: rounds, fide_id: fide_id}) do
    segments =
      [
        standard_prefix(tournament.standard),
        fide_id,
        tournament_slug(tournament),
        round_span_descriptor(rounds)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(segments, "_") <> ".trf"
  end

  defp standard_prefix("blitz"), do: "B"
  defp standard_prefix("rapid"), do: "R"
  defp standard_prefix("standard"), do: "S"
  defp standard_prefix(_other), do: "S"

  # Compact filename-safe descriptor of `rounds` (a sorted, deduped list of
  # round numbers as returned by `TrfExport.parse_rounds/2`): contiguous runs
  # collapse to `rN-M`, single rounds stay `rN`, multiple runs join with `+`
  # (e.g. `[1,2,3,5]` -> `"r1-3+5"`). Empty (no paired rounds at all) yields
  # `"all"` rather than an empty segment, so the filename never ends up with
  # a stray double underscore.
  defp round_span_descriptor([]), do: "all"

  defp round_span_descriptor(rounds) do
    rounds
    |> Enum.sort()
    |> Enum.chunk_while(
      [],
      fn round, chunk ->
        case chunk do
          [prev | _] when round == prev + 1 -> {:cont, [round | chunk]}
          [] -> {:cont, [round]}
          _ -> {:cont, Enum.reverse(chunk), [round]}
        end
      end,
      fn chunk -> {:cont, Enum.reverse(chunk), []} end
    )
    |> Enum.map_join("+", fn
      [single] -> "r#{single}"
      run -> "r#{List.first(run)}-#{List.last(run)}"
    end)
  end
end
