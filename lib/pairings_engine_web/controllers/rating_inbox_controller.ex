defmodule PairingsEngineWeb.RatingInboxController do
  @moduledoc """
  Downloading the TRF copy of a sent round from the rating period inbox
  (`PairingsEngineWeb.RatingInboxLive`).

  It is its own route rather than `ExportController.trf/2` because that one
  finds the tournament through the signed-in user's own tournaments, and an
  administrator reading the inbox is looking at other people's. It is gated
  by the same predicate as the page (`Authz.may_administer?/1`). The file is
  the one that was sent when the receipt holds it, under the name it went
  out with; a receipt from before files were kept gets a rebuilt copy,
  named and marked as one.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Authz, RatingInbox, Repo}
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}

  @doc """
  GET /admin/rating-inbox/receipts/:id/trf - the file that was sent with a
  receipt; for an older report receipt, the round as a copy.
  """
  def trf(conn, %{"id" => id}) do
    with true <- Authz.may_administer?(conn.assigns.current_scope.user),
         {int, ""} <- Integer.parse(id),
         %SentReceipt{} = receipt <- Repo.get(SentReceipt, int),
         %Tournament{deleted_at: nil} = tournament <- Repo.get(Tournament, receipt.tournament_id),
         {:ok, text, kind} <- RatingInbox.file_for(tournament, receipt, :round) do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{filename(receipt, kind)}\""
      )
      |> send_resp(200, text)
    else
      false -> refuse(conn, :forbidden, "Only an administrator can open the rating inbox.")
      _ -> refuse(conn, :not_found, "No such file.")
    end
  end

  defp filename(%SentReceipt{file_name: name}, :sent) when is_binary(name) do
    String.replace(name, ~r/[^A-Za-z0-9._ -]/, "-")
  end

  defp filename(%SentReceipt{id: id, code: code}, :sent) do
    code = code |> to_string() |> String.replace(~r/[^A-Za-z0-9-]/, "-")
    "receipt-#{id}-#{code}.trf"
  end

  defp filename(%SentReceipt{id: id, round: round, code: code}, :copy) do
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
