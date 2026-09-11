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
end
