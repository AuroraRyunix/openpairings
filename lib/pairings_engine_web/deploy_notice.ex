defmodule PairingsEngineWeb.DeployNotice do
  @moduledoc """
  Puts the pending-restart deadline on every LiveView that mounts, and keeps
  it current while the page stays open.

  Added as an `on_mount` on each `live_session` rather than to a single
  layout, because a layout cannot subscribe to anything - it is rendered,
  not a process. The assign has to exist before the first render, and the
  subscription has to belong to the LiveView's own process.

  **Every `live_session` that should show the banner needs this listed.**
  There is no central place that catches them all, so a session added later
  and not listed here silently shows no warning - which looks identical to
  "no deploy pending". `deploy_notice_test.exs` walks the router and fails
  if a session is missing it, because that is not a thing to notice by eye.
  """
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4, push_event: 3]

  alias PairingsEngine.Deploy

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Deploy.topic())
    end

    socket =
      socket
      |> announce_current()
      |> attach_hook(:deploy_notice, :handle_info, &handle_notice/2)

    {:cont, socket}
  end

  # Read the CURRENT deadline, not just future broadcasts. Someone opening a
  # page two minutes into a ten-minute countdown is precisely who the
  # warning exists for, and a broadcast only ever reaches sockets that were
  # already connected when it fired.
  defp announce_current(socket) do
    if connected?(socket) do
      socket
      |> push(Deploy.restart_at())
      |> push_event("app-version", %{version: PairingsEngineWeb.Layouts.app_version()})
    else
      socket
    end
  end

  # `:cont` on everything else, so this never swallows a message the page's
  # own handle_info was waiting for.
  defp handle_notice({:deploy_notice, restart_at}, socket) do
    {:halt, push(socket, restart_at)}
  end

  defp handle_notice(_message, socket), do: {:cont, socket}

  defp push(socket, nil), do: push_event(socket, "deploy-notice", %{restart_at: nil})

  defp push(socket, %DateTime{} = restart_at) do
    push_event(socket, "deploy-notice", %{restart_at: DateTime.to_iso8601(restart_at)})
  end
end
