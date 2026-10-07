defmodule PairingsEngineWeb.RatingInboxController do
  @moduledoc """
  Downloading the TRF copy of a sent round from the rating period inbox
  (`PairingsEngineWeb.RatingInboxLive`).

  It is its own route rather than `ExportController.trf/2` because that one
  finds the tournament through the signed-in user's own tournaments, and an
  administrator reading the inbox is looking at other people's. It is gated
  by the same predicate as the page (`Authz.may_administer?/1`), and the
  file is always a copy: the file that was sent is not kept.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Authz, RatingInbox, Repo}
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}

  @doc "GET /admin/rating-inbox/receipts/:id/trf - the round of a report receipt, as a copy."
  def trf(conn, %{"id" => id}) do
    with true <- Authz.may_administer?(conn.assigns.current_scope.user),
         {int, ""} <- Integer.parse(id),
         %SentReceipt{} = receipt <- Repo.get(SentReceipt, int),
         %Tournament{deleted_at: nil} = tournament <- Repo.get(Tournament, receipt.tournament_id),
         {:ok, text} <- RatingInbox.trf_copy(tournament, receipt, :round) do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename(receipt)}\"")
      |> send_resp(200, text)
    else
      false -> refuse(conn, :forbidden, "Only an administrator can open the rating inbox.")
      _ -> refuse(conn, :not_found, "No such file.")
    end
  end

  defp filename(%SentReceipt{id: id, round: round, code: code}) do
    code = code |> to_string() |> String.replace(~r/[^A-Za-z0-9-]/, "-")
    "receipt-#{id}-round-#{round}-#{code}_COPY-NOT-FOR-RATING.trf"
  end

  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> put_view(html: PairingsEngineWeb.ErrorHTML)
    |> text(message)
  end
end
