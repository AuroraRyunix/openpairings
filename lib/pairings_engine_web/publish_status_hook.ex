defmodule PairingsEngineWeb.PublishStatusHook do
  @moduledoc """
  Puts the publishing state in the top bar of every arbiter page.

  ## Why a hook rather than an assign per page

  The indicator's whole value is that nobody has to go and look for it: an
  arbiter should be able to tell at a glance that results are reaching the
  results site, or that they stopped on Tuesday. That means it has to be on
  every page, and a thing that must be on every page is a thing somebody
  will forget on the next one.

  ## It costs nothing per page

  `Publishing.Monitor` polls once for the whole installation and caches the
  answer; this reads that cache. No page does its own network call, which is
  the point - the check has a fifteen-second timeout, and doing it per page
  would freeze the settings screen for fifteen seconds on exactly the
  installation whose connection somebody had come to look at.

  ## The message is halted, not passed on

  Subscribing on a page's behalf means that page starts receiving a message
  it never asked for and does not handle. A LiveView with no matching
  `handle_info/2` clause crashes; one with a catch-all silently swallows it,
  which is its own bug and has already happened once in this codebase.

  So the hook handles `{:publish_status, _}` itself and returns `:halt`. A
  page can go on defining exactly the clauses it means to, and adding this
  hook cannot break one.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias PairingsEngine.Publishing.Monitor

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Monitor.topic())
    end

    socket =
      socket
      |> assign(publish_status: Monitor.status())
      |> attach_hook(:publish_status, :handle_info, &receive_status/2)

    {:cont, socket}
  end

  defp receive_status({:publish_status, status}, socket) do
    {:halt, assign(socket, publish_status: status)}
  end

  defp receive_status(_message, socket), do: {:cont, socket}
end
