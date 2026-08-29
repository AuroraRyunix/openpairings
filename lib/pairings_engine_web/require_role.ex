defmodule PairingsEngineWeb.RequireRole do
  @moduledoc """
  Keeps the machine-wide pages off an ordinary account's screen entirely.

  ## Why the actions were not enough

  Every button on Connections has been role-gated since 2026-08-29, and that
  was only half the job: a plain account could still open the page and READ
  it. What it reads is not nothing - the address this installation publishes
  to, the backup filenames and their sizes, when each rating list last
  synced, and whether the results site is answering.

  None of that is a secret in the sense of a password, and all of it is
  somebody else's business. An arbiter running a club championship has no
  reason to see the operator's infrastructure, and "the buttons don't work"
  is not the same as "this page is not for you".

  ## Two levels, matching `PairingsEngine.Authz`

    * `:support` - may LOOK. Connections is mounted with this, so the person
      answering "why did publishing stop" can see the diagnostics without
      the authority to change them.
    * `:admin` - may act. The Admin page is mounted with this.

  ## Order matters in the `on_mount` list

  This reads `current_scope`, so it has to run AFTER
  `{PairingsEngineWeb.UserAuth, :require_authenticated}` puts it there.
  Listed before it, `current_scope` is not assigned yet and every arbiter is
  bounced off their own settings.

  ## It redirects rather than 404s

  Somebody following a stale bookmark or a link from an older release should
  be told they are in the wrong place, not that the page does not exist -
  the second sends them hunting for something that was never broken.
  """
  use PairingsEngineWeb, :verified_routes

  alias PairingsEngine.Authz

  def on_mount(:support, _params, _session, socket) do
    gate(socket, &Authz.may_support?/1, "This page is for administrators.")
  end

  def on_mount(:admin, _params, _session, socket) do
    gate(socket, &Authz.may_administer?/1, "This page is for administrators.")
  end

  defp gate(socket, allowed?, message) do
    if allowed?.(socket.assigns.current_scope && socket.assigns.current_scope.user) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, message)
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end
end
