defmodule PairingsEngineWeb.UpdateNotice do
  @moduledoc """
  Puts the pending-update notice in the top bar of every arbiter page - on a
  desktop install only.

  Same shape as `PairingsEngineWeb.PublishStatusHook`, for the same reason:
  `PairingsEngine.Updates.notice_for_render/0` is not free (it composes an
  `:ets` read with a filesystem check and a database query - see its own
  moduledoc), and the top bar renders on every page of every session. So it
  is computed once here, at mount, assigned, and threaded through
  `Layouts.app` exactly like `publish_status` - not read fresh on every
  render, which is what a page that forgets to thread it gets instead:
  nothing, rather than a repeated query. See `Layouts.app`'s own attr doc.

  Third of the three desktop-only guards described in
  `PairingsEngine.Updates`'s moduledoc: `eligible?/0` gates whether this
  even subscribes, so a hosted server's LiveViews never listen on a topic
  nothing broadcasts to it on anyway, and `notice_for_render/0` gates the
  assign itself, so nothing here can show the banner even if state somehow
  existed.

  **Every `live_session` that should show it needs this listed** - the same
  discipline `PairingsEngineWeb.DeployNotice` documents, and for the same
  reason: there is no central place that catches a session added later and
  left off this list, and that looks identical to "no update pending".

  ## The button is handled here too, not per-LiveView

  `PairingsEngineWeb.Components.Layouts.app/1` (where the notice actually
  renders) is a function component embedded in every one of those
  LiveViews, not a LiveView itself, so a plain `phx-click="install_and_restart"`
  would need a matching `handle_event` in every single one of them to work
  anywhere. Attaching a second hook here, for `:handle_event` this time,
  reaches every `live_session` that already lists this module - one place,
  same as the notice's own composition.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias PairingsEngine.Updates
  alias PairingsEngine.Updates.Checker

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and Updates.eligible?() do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Checker.topic())
    end

    socket =
      socket
      |> assign(update_notice: Updates.notice_for_render())
      |> attach_hook(:update_notice, :handle_info, &receive_update/2)
      |> attach_hook(:update_install, :handle_event, &receive_install_click/3)

    {:cont, socket}
  end

  # Recomposed rather than trusting the broadcast payload verbatim: the
  # broadcast only carries `Checker`'s half (version/tag/url), and the
  # install kind and the running-tournament caveat still need combining in -
  # see `Updates.notice_for_render/0`.
  defp receive_update({:update_notice, _info}, socket) do
    {:halt, assign(socket, update_notice: Updates.notice_for_render())}
  end

  defp receive_update(_message, socket), do: {:cont, socket}

  # `"install_and_restart"` always halts here, whatever the socket's assigns
  # turn out to hold - never falls through to `:cont`, unlike every other
  # event name. `:cont` would hand it to the LiveView actually mounted
  # (TournamentsLive, PairingsLive, ...), none of which define a matching
  # `handle_event/3` clause, since this button is not theirs to know about -
  # so a stale click (the notice already gone, a double click) would crash
  # the LiveView instead of quietly doing nothing.
  #
  # Guarded on the socket's OWN `update_notice` assign, not on anything the
  # client sent - it is nil everywhere but a desktop install that has
  # already found a newer release (see `Updates.eligible?/0` and
  # `Updates.notice_for_render/0`), so a hosted server's socket can never
  # reach the install branch no matter what a crafted client message
  # claims. `Updates.request_install_and_restart/0` re-checks `eligible?/0`
  # again regardless - see its own comment.
  defp receive_install_click("install_and_restart", _params, socket) do
    case socket.assigns[:update_notice] do
      %{install_kind: :velopack_per_user} = notice ->
        # `!`, not `not` - notice[:installing] is nil (not false) on every
        # request but the first, since notice_for_render/0's own map never
        # carries this key at all; `not` requires a strict boolean and
        # raises on nil, `!` treats nil and false alike.
        if Updates.install_and_restart_available?() and !notice[:installing] do
          Updates.request_install_and_restart()
          {:halt, assign(socket, update_notice: Map.put(notice, :installing, true))}
        else
          {:halt, socket}
        end

      _ ->
        {:halt, socket}
    end
  end

  defp receive_install_click(_event, _params, socket), do: {:cont, socket}
end
