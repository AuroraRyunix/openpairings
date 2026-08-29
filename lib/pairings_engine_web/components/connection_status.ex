defmodule PairingsEngineWeb.Components.ConnectionStatus do
  @moduledoc """
  Whether this machine can publish, right now.

  ## Why it exists

  Publishing is deliberately invisible: it is queued, retried, and never in the
  way of pairing a round. That is right, and it has a cost - an arbiter had no
  way to tell "my results are going out" from "nothing has left this laptop
  since Tuesday", because both look exactly like nothing happening.

  So there is one indicator, and it answers three questions in the order they
  matter:

    1. **Can this machine reach the results site at all?** Green, amber or red,
       with the reason in words. Colour alone is not the answer - it is
       unreadable to a colourblind arbiter and ambiguous to everyone at a
       glance.
    2. **How far away is it?** The round trip in milliseconds. On the hosted
       box, where both applications share a machine, this is a single-digit
       number, and "3 ms" is a more convincing "yes, really connected" than a
       green dot on its own.
    3. **Is anything moving?** The queue depth, and when something last
       actually went out. An empty queue means either "everything has been
       sent" or "nothing was ever queued"; those look identical, so the
       timestamp is what tells them apart.

  ## Refused is not unreachable

  A server that answers and rejects the token is a working network and a wrong
  secret. A server that does not answer is a network problem. They want
  opposite fixes, so they get different words and different colours rather than
  one "error" state that sends an arbiter to check the wrong thing.

  ## The busy state

  While the queue is non-empty the indicator goes amber and says so. This is
  the state the whole thing was asked for: an arbiter enters the last result of
  a round and wants to see something move.
  """
  use Phoenix.Component

  use Gettext, backend: PairingsEngineWeb.Gettext

  attr :status, :map,
    default: nil,
    doc: "from `PairingsEngine.Publishing.status/0`, or nil while the first check is in flight"

  attr :compact, :boolean,
    default: false,
    doc: "one line, for a page that is about something else"

  # Nil is a real state, not a missing one: the check is a network round trip
  # and the page renders before it can possibly have finished. Saying "checking"
  # is honest; guessing green and correcting a second later is not, and guessing
  # red would put a scare on a page that is fine.
  def connection_status(%{status: nil} = assigns) do
    ~H"""
    <div class={["conn-status", "is-unknown", @compact && "is-compact"]}>
      <span class="conn-dot" aria-hidden="true"></span>
      <div class="conn-body">
        <p class="conn-line"><strong>{gettext("Checking the connection...")}</strong></p>
      </div>
    </div>
    """
  end

  def connection_status(assigns) do
    assigns = assign(assigns, :tone, tone(assigns.status))

    ~H"""
    <div class={["conn-status", "is-#{@tone}", @compact && "is-compact"]}>
      <span class="conn-dot" aria-hidden="true"></span>

      <div class="conn-body">
        <p class="conn-line">
          <strong>{headline(@status)}</strong>
          <span :if={@status.latency_ms} class="conn-latency">{@status.latency_ms} ms</span>
        </p>

        <p :if={not @compact} class="conn-detail">{@status.message}</p>

        <p class="conn-detail">
          <span :if={@status.endpoint}>{host(@status.endpoint)}</span>
          <span :if={@status.pending > 0}>
            {ngettext(
              "1 tournament waiting to send",
              "%{count} tournaments waiting to send",
              @status.pending
            )}
          </span>
          <span :if={@status.pending == 0 and @status.last_published_at}>
            {gettext("last sent %{ago}", ago: ago(@status.last_published_at))}
          </span>
          <span :if={@status.pending == 0 and is_nil(@status.last_published_at)}>
            {gettext("nothing sent from this machine yet")}
          </span>
        </p>
      </div>
    </div>
    """
  end

  # Amber while work is in flight, whatever the connection says: "connected,
  # and eight tournaments are still waiting" is not a green situation.
  defp tone(%{state: :connected, pending: pending}) when pending > 0, do: "busy"
  defp tone(%{state: :connected}), do: "ok"
  defp tone(%{state: :refused}), do: "refused"
  defp tone(%{state: :unreachable}), do: "down"
  defp tone(%{state: :unconfigured}), do: "off"

  defp headline(%{state: :connected, pending: pending}) when pending > 0, do: gettext("Sending")
  defp headline(%{state: :connected}), do: gettext("Connected")
  defp headline(%{state: :refused}), do: gettext("Token refused")
  defp headline(%{state: :unreachable}), do: gettext("Cannot reach the results site")
  defp headline(%{state: :unconfigured}), do: gettext("Not set up")

  defp host(endpoint) do
    case URI.parse(endpoint) do
      %URI{host: host} when is_binary(host) -> host
      _ -> endpoint
    end
  end

  # Deliberately coarse. Nobody needs "47 seconds ago" for this, and a number
  # that changes every render draws the eye to the one part of the box that
  # does not matter.
  defp ago(at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 60 -> gettext("just now")
      s when s < 3600 -> gettext("%{n} min ago", n: div(s, 60))
      s when s < 86_400 -> gettext("%{n} h ago", n: div(s, 3600))
      s -> gettext("%{n} days ago", n: div(s, 86_400))
    end
  end
end
