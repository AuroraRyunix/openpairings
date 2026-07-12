defmodule PairingsEngineWeb.ExportController do
  @moduledoc """
  Downloads for tournament data: FIDE TRF16 (`PairingsEngine.TrfExport`) and
  full-fidelity JSON backups (`PairingsEngine.TournamentExport`). See
  `docs/import-export.md`. JSON *import* isn't here — a file upload can't be
  a plain GET download route — see the "Import backup" control on
  `PairingsEngineWeb.TournamentsLive`, backed by
  `PairingsEngine.TournamentImport`.

  Every single-tournament action scopes the tournament through
  `Tournaments.get_authorized_tournament!/2`, so a tournament id the
  current user doesn't own and isn't a collaborator on 404s the same way
  the rest of the app does.
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{TournamentExport, Tournaments, TrfExport}

  @doc "GET /t/:id/export/trf?rounds=1-5 — TRF16 text download, all or selected rounds."
  def trf(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)

    case TrfExport.export(tournament, params["rounds"]) do
      {:ok, text} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename(tournament, "trf")}\"")
        |> send_resp(200, text)

      {:error, %PairingsEngine.Trf.ValidationError{message: message}} ->
        conn
        |> put_flash(:error, "Could not export TRF: #{message}")
        |> redirect(to: ~p"/t/#{tournament.id}/pairings")
    end
  end

  @doc "GET /t/:id/export/json — full-fidelity JSON backup of one tournament."
  def json(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    envelope = TournamentExport.export_tournament(tournament)

    send_json_download(conn, envelope, filename(tournament, "json"))
  end

  @doc "GET /export/tournaments.json — full-fidelity JSON backup of every tournament the current user owns."
  def all_json(conn, _params) do
    envelope = TournamentExport.export_all(conn.assigns.current_scope)
    send_json_download(conn, envelope, "openpairings-export-#{Date.to_iso8601(Date.utc_today())}.json")
  end

  defp send_json_download(conn, envelope, filename) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, Jason.encode!(envelope))
  end

  defp filename(tournament, ext) do
    slug =
      tournament.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "#{slug}.#{ext}"
  end
end
