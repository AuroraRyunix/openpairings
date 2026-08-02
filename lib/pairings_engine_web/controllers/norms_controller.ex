defmodule PairingsEngineWeb.NormsController do
  @moduledoc """
  Downloads for the four official FIDE report/norm `.xlsx` forms (IT3, FA1,
  IA1, IT4), filled in place from the tournament's data by
  `PairingsEngine.Norms.Forms` + `PairingsEngine.Norms.XlsxFill`.

  Every action scopes the tournament through
  `Tournaments.get_authorized_tournament!/2`, so a tournament id the current
  user doesn't own and isn't a collaborator on 404s the same way the rest
  of the app does.

  ## Combined reports (festivals)

  `it3/2`, `fa1/2` and `ia1/2` also accept two optional query params for a
  Belgian-federation arbiter running several category groups as one
  festival, each group its own `Tournament` row in the app:

    * `combine` — a comma-separated list of tournament ids to merge (the
      current tournament's `id` plus any others), e.g. `combine=12,7,9`.
    * `master` — which of those ids supplies every header/schedule field
      (and the virtual report's name — see `PairingsEngine.Norms.Combine`).

  Every id in `combine` is authorized individually via
  `Tournaments.get_authorized_tournament!/2`, exactly like the single-
  tournament `id` — a forged id in there 404s the same way. When `combine`
  is absent or blank, behavior is unchanged from the single-tournament path.
  A duplicate player across the selected tournaments redirects back to the
  Norms tab with a friendly `:error` flash instead of a 500 — see
  `PairingsEngine.Norms.Combine.error_message/1`.
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Standings, Tournaments}
  alias PairingsEngine.Norms.{Combine, Forms, XlsxFill}

  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @doc "IT3 — Tournament Report Form, auto-available for the whole tournament."
  def it3(conn, %{"id" => id} = params) do
    case load_scope(conn, id, params) do
      {:ok, tournament, players} ->
        render_xlsx_result(conn, :it3, tournament, Forms.it3_result(tournament, players))

      {:error, dup} ->
        redirect_duplicate(conn, id, dup)
    end
  end

  @doc """
  FA1 — FIDE Arbiter norm report for one candidate, supplied via
  `?candidate[last_name]=...&candidate[first_name]=...&candidate[fide_id]=...&candidate[federation]=...`.
  """
  def fa1(conn, %{"id" => id} = params) do
    case load_scope(conn, id, params) do
      {:ok, tournament, players} ->
        candidate = Map.get(params, "candidate", %{})
        render_xlsx(conn, :fa1, tournament, Forms.fa1_fills(tournament, players, candidate))

      {:error, dup} ->
        redirect_duplicate(conn, id, dup)
    end
  end

  @doc "IA1 — International Arbiter norm report; same params as `fa1/2`."
  def ia1(conn, %{"id" => id} = params) do
    case load_scope(conn, id, params) do
      {:ok, tournament, players} ->
        candidate = Map.get(params, "candidate", %{})
        render_xlsx(conn, :ia1, tournament, Forms.ia1_fills(tournament, players, candidate))

      {:error, dup} ->
        redirect_duplicate(conn, id, dup)
    end
  end

  @doc "IT4 — Title/Norm report, listing every player with a claimed title norm."
  def it4(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    entries = Standings.standings(tournament)

    render_xlsx(conn, :it4, tournament, Forms.it4_fills(tournament, entries))
  end

  # Single-tournament path (the common case — `combine` absent or blank):
  # unchanged from before `combine`/`master` existed. Combined path: every
  # id in `combine` (in the order given) is authorized and its players
  # loaded exactly like the single-tournament `id`, then merged via
  # `PairingsEngine.Norms.Combine.combine/2` — `master` picks which of
  # those ids' index supplies the header/schedule fields, defaulting to the
  # first id if `master` is missing or not one of `combine`'s ids.
  defp load_scope(conn, _id, %{"combine" => combine} = params) when combine not in [nil, ""] do
    scope = conn.assigns.current_scope
    ids = combine |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    pairs =
      Enum.map(ids, fn cid ->
        tournament = Tournaments.get_authorized_tournament!(scope, cid)
        {tournament, Tournaments.list_players(tournament.id)}
      end)

    master_index = Enum.find_index(ids, &(&1 == params["master"])) || 0

    case Combine.combine(pairs, master_index) do
      {:ok, {tournament, players}} -> {:ok, tournament, players}
      {:error, dup} -> {:error, dup}
    end
  end

  defp load_scope(conn, id, _params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    {:ok, tournament, Tournaments.list_players(tournament.id)}
  end

  defp redirect_duplicate(conn, id, dup) do
    conn
    |> put_flash(:error, Combine.error_message(dup))
    |> redirect(to: ~p"/t/#{id}/norms")
  end

  defp render_xlsx(conn, kind, tournament, fills) do
    render_xlsx_result(conn, kind, tournament, XlsxFill.fill(Forms.template_path(kind), fills))
  end

  defp render_xlsx_result(conn, kind, tournament, result) do
    case result do
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
        |> send_resp(
          500,
          "Could not generate #{kind |> Atom.to_string() |> String.upcase()}: #{inspect(reason)}"
        )
    end
  end
end
