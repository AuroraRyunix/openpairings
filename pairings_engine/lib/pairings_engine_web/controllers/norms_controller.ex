defmodule PairingsEngineWeb.NormsController do
  @moduledoc """
  Downloads for the four official FIDE report/norm `.xlsx` forms (IT3, FA1,
  IA1, IT4), filled in place from the tournament's data by
  `PairingsEngine.Norms.Forms` + `PairingsEngine.Norms.XlsxFill`.

  Every action scopes the tournament through
  `Tournaments.get_authorized_tournament!/2`, so a tournament id the current
  user doesn't own and isn't a collaborator on 404s the same way the rest
  of the app does.
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Standings, Tournaments}
  alias PairingsEngine.Norms.{Forms, XlsxFill}

  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @doc "IT3 — Tournament Report Form, auto-available for the whole tournament."
  def it3(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)

    render_xlsx(conn, :it3, tournament, Forms.it3_fills(tournament, players))
  end

  @doc """
  FA1 — FIDE Arbiter norm report for one candidate, supplied via
  `?candidate[last_name]=...&candidate[first_name]=...&candidate[fide_id]=...&candidate[federation]=...`.
  """
  def fa1(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)
    candidate = Map.get(params, "candidate", %{})

    render_xlsx(conn, :fa1, tournament, Forms.fa1_fills(tournament, players, candidate))
  end

  @doc "IA1 — International Arbiter norm report; same params as `fa1/2`."
  def ia1(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)
    candidate = Map.get(params, "candidate", %{})

    render_xlsx(conn, :ia1, tournament, Forms.ia1_fills(tournament, players, candidate))
  end

  @doc "IT4 — Title/Norm report, listing every player with a claimed title norm."
  def it4(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    entries = Standings.standings(tournament)

    render_xlsx(conn, :it4, tournament, Forms.it4_fills(tournament, entries))
  end

  defp render_xlsx(conn, kind, tournament, fills) do
    case XlsxFill.fill(Forms.template_path(kind), fills) do
      {:ok, binary} ->
        conn
        |> put_resp_content_type(@xlsx_content_type)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{Forms.download_filename(kind, tournament)}\""
        )
        |> send_resp(200, binary)

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "Could not generate #{kind |> Atom.to_string() |> String.upcase()}: #{inspect(reason)}")
    end
  end
end
