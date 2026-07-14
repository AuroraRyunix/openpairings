defmodule PairingsEngineWeb.ToolsController do
  @moduledoc """
  `GET /tools` (redirects to the only tool there is right now) and
  `GET /tools/download/:token/:form` — the download half of the public,
  no-login arbiter tools page (`PairingsEngineWeb.ToolsNormsLive`, see
  docs/tools.md).

  Looks up `:token` in `PairingsEngine.Tools.Session` (never the database),
  combines the parsed tournament(s) with `PairingsEngine.Norms.Combine`,
  layers the officials/candidate overlay with `PairingsEngine.Tools.Overlay`,
  and fills the same `.xlsx` templates `PairingsEngineWeb.NormsController`
  does via `PairingsEngine.Norms.Forms` + `PairingsEngine.Norms.XlsxFill`.

  Every failure mode reachable from hostile or merely stale input — an
  unknown/expired token, no successfully-parsed files, a `Combine`
  duplicate-player conflict — renders a small friendly HTML page instead of
  a 500 or a crash.
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.Norms.{Combine, Forms, XlsxFill}
  alias PairingsEngine.Tools.{Overlay, Session}

  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @forms ~w(it3 fa1 ia1)

  def index(conn, _params), do: redirect(conn, to: ~p"/tools/norms")

  def download(conn, %{"token" => token, "form" => form}) when form in @forms do
    kind = String.to_existing_atom(form)

    with {:ok, session} <- fetch_tools_session(token),
         {:ok, pairs} <- parsed_pairs(session),
         {:ok, {tournament, players}} <- Combine.combine(pairs, Map.get(session, :master_index, 0)) do
      tournament = Overlay.apply(tournament, Map.get(session, :overlay, %{}))
      fills = build_fills(kind, tournament, players, Map.get(session, :candidate, %{}))
      render_xlsx(conn, kind, tournament, fills)
    else
      {:error, reason} -> error_page(conn, friendly_error(reason))
    end
  end

  def download(conn, %{"form" => _other}), do: error_page(conn, "Unknown report — go back and pick IT3, FA1 or IA1.")

  ## ---------- session + combine plumbing ----------

  # Named to avoid clashing with the imported `Plug.Conn.fetch_session/1`.
  defp fetch_tools_session(token) do
    case Session.get(token) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, :session_missing}
    end
  end

  defp parsed_pairs(session) do
    pairs =
      session
      |> Map.get(:files, [])
      |> Enum.filter(&is_nil(&1.error))
      |> Enum.map(&{&1.tournament, &1.players})

    case pairs do
      [] -> {:error, :no_files}
      pairs -> {:ok, pairs}
    end
  end

  defp build_fills(:it3, tournament, players, _candidate), do: Forms.it3_fills(tournament, players)
  defp build_fills(:fa1, tournament, players, candidate), do: Forms.fa1_fills(tournament, players, candidate)
  defp build_fills(:ia1, tournament, players, candidate), do: Forms.ia1_fills(tournament, players, candidate)

  ## ---------- rendering ----------

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
        error_page(conn, "Could not generate this report: #{inspect(reason)}")
    end
  end

  defp friendly_error(:session_missing),
    do: "This session has expired or wasn't found — your files were never saved, so please re-upload them."

  defp friendly_error(:no_files),
    do: "No files have been successfully parsed yet — upload at least one .swar or .trf file first."

  defp friendly_error({:duplicate_players, _} = reason), do: Combine.error_message(reason)

  defp error_page(conn, message) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, error_html(message))
  end

  defp error_html(message) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>Arbiter tools — OpenPairings</title>
        <meta name="viewport" content="width=device-width, initial-scale=1" />
      </head>
      <body style="font-family: system-ui, sans-serif; max-width: 520px; margin: 80px auto; padding: 0 20px; text-align: center; color: #1c1a15;">
        <h1 style="font-size: 20px;">#{escape(message)}</h1>
        <p><a href="/tools/norms">Back to the arbiter tools</a></p>
      </body>
    </html>
    """
  end

  defp escape(text), do: Plug.HTML.html_escape(text)
end
