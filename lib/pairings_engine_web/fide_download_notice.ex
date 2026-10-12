defmodule PairingsEngineWeb.FideDownloadNotice do
  @moduledoc """
  The question a desktop install asks before it spends 41 MB: a banner on
  every arbiter page, with "Download now", "Later" and "Don't ask again".

  The look at FIDE stays automatic (`PairingsEngine.Fide.AutoSync`, one `HEAD`
  request); the download does not. The banner exists only on a desktop
  install in `:ask` mode with something pending, and only an administrator
  sees it or can press its buttons - the same people who may press "Update
  from FIDE" on the Connections page.

  Built like `PairingsEngineWeb.UpdateNotice`, for the same reason: the layout
  is a function component embedded in every LiveView, so the buttons' events
  are caught here once instead of in forty `handle_event/3` clauses. They
  always halt, so a stale click lands nowhere instead of crashing a page that
  has never heard of them. Every `live_session` that lists `UpdateNotice`
  lists this too.

  "Later" hides the banner for 24 hours, restarts included. "Don't ask again"
  sets the mode to `:never`; the Connections page can set it back.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias PairingsEngine.{Audit, Authz}
  alias PairingsEngine.Fide.{AutoSync, Sync}

  @events ~w(fide_download_now fide_download_later fide_download_never)

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and Authz.local_mode?() do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, AutoSync.topic())
    end

    socket =
      socket
      |> assign(fide_notice: AutoSync.notice())
      |> attach_hook(:fide_notice, :handle_info, &receive_change/2)
      |> attach_hook(:fide_notice_click, :handle_event, &receive_click/3)

    {:cont, socket}
  end

  defp receive_change({:fide_download_notice, :changed}, socket) do
    {:halt, assign(socket, fide_notice: AutoSync.notice())}
  end

  defp receive_change(_message, socket), do: {:cont, socket}

  defp receive_click(event, _params, socket) when event in @events do
    if admin?(socket) and Authz.local_mode?() do
      act(event, socket)
    end

    {:halt, assign(socket, fide_notice: AutoSync.notice())}
  end

  defp receive_click(_event, _params, socket), do: {:cont, socket}

  defp admin?(%{assigns: %{current_scope: %{user: user}}}), do: Authz.may_administer?(user)
  defp admin?(_socket), do: false

  defp act("fide_download_now", socket) do
    if Sync.status().status not in [:downloading, :importing] do
      Sync.start_sync()
      Audit.log_system(socket.assigns.current_scope, "fide.sync_started", %{})
    end
  end

  defp act("fide_download_later", _socket), do: AutoSync.snooze()
  defp act("fide_download_never", _socket), do: AutoSync.put_mode(:never)
end
