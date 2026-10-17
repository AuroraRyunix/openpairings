defmodule PairingsEngineWeb.EnrollmentRevokedHook do
  @moduledoc """
  Takes `{:mobile_enrollment_revoked, id}` off every tournament page's hands.

  `PairingsEngine.Mobile.revoke/1` broadcasts it on the tournament's topic so
  the revoked phone finds out at once. That topic is also the one every
  arbiter page of the tournament follows, and a LiveView with no
  `handle_info/2` clause for a message it receives crashes. Revoking a phone
  therefore took down the Pairings page, and about twenty others, of anyone
  who had the tournament open. Only the phone's own page was ever meant to
  hear it.

  Handled here once, for the whole `live_session`, so that a page cannot
  forget it and the next page cannot either. A page that lists enrollments
  (it has an `:enrollments` assign) reloads the list; every other page has
  nothing to refresh. The message is always halted: the page's own clauses are
  never asked about it.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias PairingsEngine.Mobile

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :enrollment_revoked, :handle_info, &receive_revoked/2)}
  end

  defp receive_revoked({:mobile_enrollment_revoked, _id}, socket) do
    case socket.assigns do
      %{enrollments: _, tournament: %{id: tournament_id}} ->
        {:halt, assign(socket, :enrollments, Mobile.list_enrollments(tournament_id))}

      _ ->
        {:halt, socket}
    end
  end

  defp receive_revoked(_message, socket), do: {:cont, socket}
end
