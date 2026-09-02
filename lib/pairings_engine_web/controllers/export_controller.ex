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
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{PgnExport, SwarExport, TournamentExport, Tournaments, TrfExport}

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
  `PairingsEngine.SwarExport`'s moduledoc for exactly what this can and
  cannot round-trip, and why it has never been verified against a real
  SWAR install.
  """
  def swar(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    binary = SwarExport.export(tournament.id)

    conn
    |> put_resp_content_type("application/octet-stream")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"#{filename(tournament, "swar")}\""
    )
    |> send_resp(200, binary)
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
