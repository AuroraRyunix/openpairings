defmodule PairingsEngineWeb.ManubriumApi.IncidentController do
  @moduledoc """
  An incident's photo from the Manubrium app: adding one to an incident
  already logged, and fetching it.

  A photo taken while logging travels inside the incident's queue entry
  (`POST /sync`, `photo`), as the hall pages' does. This is for the photo
  taken afterwards. Both land in the same place - the incident's photo row,
  in the tournament's own database, through `Incidents.check_photo/1`: a
  JPEG by its first bytes, never by what the sender called it, and at most
  `Incidents.photo_max/0` bytes.

  Who may: the organiser and editors (`:desk`), the same people the desk's
  incidents page shows photos to (`PairingsEngineWeb.IncidentPhotoController`).
  An arbiter's phone can send a photo with an incident; it cannot read
  anyone's back.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Incidents, Tournaments}
  alias PairingsEngineWeb.ManubriumApi.{Json, Reply}

  # base64 of the largest photo, with room for padding.
  @photo_b64_max div(Incidents.photo_max() * 4, 3) + 4

  @doc """
  POST /tournaments/:id/incidents/:incident_id/photo - `{photo: base64 JPEG}`.
  201 with the incident; 409 when it has one already, 413 too large, 415
  not a JPEG.
  """
  def attach_photo(conn, %{"id" => id, "incident_id" => incident_id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         :ok <- writable(conn, t),
         {:ok, iid} <- id_param(conn, incident_id),
         {:ok, data} <- decode(conn, params["photo"]) do
      case Incidents.attach_photo(t.id, iid, data, conn.assigns.current_scope) do
        {:ok, incident} ->
          conn |> put_status(201) |> json(%{incident: Json.incident(incident)})

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc "GET /tournaments/:id/incidents/:incident_id/photo - the JPEG, or 404."
  def photo(conn, %{"id" => id, "incident_id" => incident_id}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, iid} <- id_param(conn, incident_id) do
      case Incidents.get_photo(t.id, iid) do
        %{data: data} when is_binary(data) ->
          # Checked again on the way out: nothing but a JPEG leaves here.
          case Incidents.check_photo(data) do
            :ok ->
              conn
              |> put_resp_header("cache-control", "private, no-store")
              |> put_resp_header("x-content-type-options", "nosniff")
              |> put_resp_content_type("image/jpeg", nil)
              |> send_resp(200, data)

            {:error, _} ->
              Reply.refuse(conn, :not_found)
          end

        _ ->
          Reply.refuse(conn, :not_found)
      end
    else
      {:halt, conn} -> conn
    end
  end

  defp decode(conn, b64) when is_binary(b64) and byte_size(b64) > @photo_b64_max,
    do: {:halt, Reply.refuse(conn, :photo_too_large)}

  defp decode(conn, b64) when is_binary(b64) and b64 != "" do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, data} -> {:ok, data}
      :error -> {:halt, Reply.refuse(conn, :not_a_photo)}
    end
  end

  defp decode(conn, _b64),
    do: {:halt, Reply.error(conn, 400, "bad_request", gettext("A photo is needed."))}

  defp writable(conn, t) do
    case Tournaments.ensure_writable(t) do
      :ok -> :ok
      {:error, reason} -> {:halt, Reply.refuse(conn, reason)}
    end
  end

  defp id_param(conn, value) do
    case Reply.to_id(value) do
      {:ok, n} -> {:ok, n}
      :error -> {:halt, Reply.error(conn, 400, "bad_request", gettext("Not a number."))}
    end
  end
end
