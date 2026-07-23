defmodule PairingsEngineWeb.MobileAuth do
  @moduledoc """
  Session handling for the no-account mobile result-entry flow (see
  `PairingsEngine.Mobile`). An enrolled browser carries `:mobile_enrollment_id`
  in its session; this re-validates it (active, not expired/revoked) on every
  request and exposes the enrollment + its tournament.
  """
  use PairingsEngineWeb, :verified_routes

  import Plug.Conn, only: [put_session: 3, delete_session: 2]
  import Phoenix.Component, only: [assign: 3]

  alias PairingsEngine.{Mobile, Tournaments}

  @session_key :mobile_enrollment_id

  @doc "Stores an enrollment in the session (called by the enroll controller)."
  def put_enrollment(conn, enrollment), do: put_session(conn, @session_key, enrollment.id)

  @doc "Clears the mobile enrollment from the session."
  def clear_enrollment(conn), do: delete_session(conn, @session_key)

  @doc """
  LiveView `on_mount` for `/m/results`: loads the active enrollment + its
  tournament from the session, or redirects to the code-entry page.
  """
  def on_mount(:require_enrollment, _params, session, socket) do
    case load(session[Atom.to_string(@session_key)] || session[@session_key]) do
      {enrollment, tournament} ->
        {:cont,
         socket
         |> assign(:mobile_enrollment, enrollment)
         |> assign(:tournament, tournament)}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/m")}
    end
  end

  defp load(nil), do: nil

  defp load(id) do
    with %Mobile.Enrollment{} = enrollment <- Mobile.get_active(id),
         %Tournaments.Tournament{} = tournament <-
           Tournaments.get_tournament(enrollment.tournament_id) do
      {enrollment, tournament}
    else
      _ -> nil
    end
  end
end
