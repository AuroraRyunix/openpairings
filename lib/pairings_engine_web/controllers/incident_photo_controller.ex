defmodule PairingsEngineWeb.IncidentPhotoController do
  @moduledoc """
  An incident's photo (`GET /t/:id/incidents/:incident_id/photo`), for the
  desk's incidents page and nobody else: whoever may open the tournament
  (`Tournaments.get_authorized_tournament/2` - the owner and the editors,
  not an arbiter and not a phone), and a 404 for everyone who may not,
  rather than a 403 that confirms there is something to see.

  Sent as what it was checked to be when it arrived (a JPEG, by its first
  bytes), with `nosniff`, never cached by anything in between, and never
  under a public page's address.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Incidents, Tournaments}

  def show(conn, %{"id" => id, "incident_id" => incident_id}) do
    with %{} = tournament <- Tournaments.get_authorized_tournament(conn.assigns.current_scope, id),
         {incident_id, ""} <- Integer.parse(incident_id),
         %{data: data} when is_binary(data) <-
           Incidents.get_photo(tournament.id, incident_id),
         :ok <- Incidents.check_photo(data) do
      # Always a JPEG: nothing else gets past check_photo/1 on the way in
      # or on the way out, so the type is a literal, not the stored column.
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:binary, data},
        filename: "incident-#{incident_id}.jpg",
        content_type: "image/jpeg",
        disposition: :inline
      )
    else
      _ -> conn |> put_status(404) |> text("Not found.")
    end
  end
end
