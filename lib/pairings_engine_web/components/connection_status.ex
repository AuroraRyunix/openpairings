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
    2. **How far away is it?** The round trip in milliseconds - a number is a
       more convincing "yes, really connected" than a green dot on its own.

       This once claimed the hosted box would show a single digit, "because
       both applications share a machine". It shows about 40 ms, and the
       claim was wrong rather than the measurement: `Publishing.endpoint/0`
       is the PUBLIC address, so the check leaves the box, goes out to
       Cloudflare and comes back in through the tunnel. Same machine, and
       nowhere near loopback.

       It cannot simply be pointed at `localhost` either, because that field
       does two jobs: `PairingsEngineWeb.PublicLink` builds every share link,
       QR code and printed URL from it, and spectators cannot follow
       `http://localhost:4004`. Splitting "where do I publish" from "where do
       spectators go" would fix both, and is not a config change.
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
          <%!-- What a round actually costs to publish. A snapshot is the
                whole tournament rather than a delta, so this is the only
                figure that says so - and it moves: the tie-break working
                multiplied it by about 3.4 on a large event, which no queue
                depth would have shown. --%>
          <span :if={@status[:last_publish_bytes]}>
            {gettext("%{size} last sent", size: bytes(@status[:last_publish_bytes]))}
          </span>
        </p>
      </div>
    </div>
    """
  end

  attr :status, :map, default: nil, doc: "from `PairingsEngine.Publishing.Monitor.status/0`"

  @doc """
  The same answer as a top-bar pill, small enough to live beside the clock.

  ## Why the top bar and not only the settings page

  An arbiter does not visit the settings page during a round; they pair, they
  enter results, and they trust that it is going out. That trust is the thing
  worth instrumenting, because when it is misplaced the symptom is *nothing
  happening* - which looks exactly like everything being fine.

  So the state is where it is seen without going to look: a word, a colour and
  the round trip, on every page.

  ## It opens rather than navigates

  A pill that says "Offline" and cannot be acted on is a worry rather than
  information, so it has always been clickable. It used to `navigate` to
  `/fide` - the rating-list page, which has nothing to do with publishing and
  was plainly a mistake; there is no global publishing page for it to have
  meant instead, because the settings that matter are per-tournament.

  So it opens the FULL indicator in place: the same component the settings
  page renders, with the reason in words, the endpoint, the queue depth, when
  something last went out and how big it was. That is what somebody clicking
  a status light wants - more status, not a different page - and it works on
  every page, including the ones with no tournament to navigate to.

  A `<details>` sharing the `topbar-popover` name with the Advanced and
  Settings menus, so opening one closes the others.

  ## The word carries the state, not the colour

  Same reason as the full indicator: colour alone is unreadable to a
  colourblind arbiter and ambiguous to everyone at a glance. The colour is
  the thing that catches the eye across a room; the word is the thing that
  says what to do.
  """
  def publish_pill(%{status: nil} = assigns) do
    ~H"""
    <span class="pub-pill is-unknown" title={gettext("Checking the results-site connection")}>
      <span class="pub-dot" aria-hidden="true"></span>
      <span class="pub-word">{gettext("Checking...")}</span>
    </span>
    """
  end

  def publish_pill(assigns) do
    assigns = assign(assigns, :tone, tone(assigns.status))

    ~H"""
    <details class="topbar-menu pub-menu" name="topbar-popover">
      <summary
        class={["pub-pill", "is-#{@tone}"]}
        title={pill_title(@status)}
        aria-label={pill_title(@status)}
      >
        <span class="pub-dot" aria-hidden="true"></span>
        <span class="pub-word">{pill_word(@status)}</span>
        <span :if={@status.latency_ms && @status.state == :connected} class="pub-ms">
          {@status.latency_ms} ms
        </span>
      </summary>

      <div class="topbar-menu-panel pub-panel">
        <.connection_status status={@status} />
        <.stability_line />
      </div>
    </details>
    """
  end

  # Deliberately shorter than the full indicator's headline. "Cannot reach
  # the results site" is the right sentence on a settings page and too long
  # for a strip that also holds the language picker and an email address.
  @doc """
  How the connection has BEHAVED, as opposed to what it is doing now.

  The light answers "right now", and the failure it describes worst is the
  intermittent one: a hall's wifi that drops for fifteen seconds every few
  minutes reads green almost every time somebody looks, while results arrive
  late for no visible reason. A green light that can also say it has been
  green for ten minutes is worth more than one that cannot.

  Renders nothing until there is enough history to make the claim. Four
  checks is two minutes of evidence, and "steady for the last 10 minutes"
  from a process that started ninety seconds ago would be a lie told
  confidently.
  """
  def stability_line(assigns) do
    assigns = assign(assigns, :window, PairingsEngine.Publishing.Monitor.stability())

    ~H"""
    <p :if={@window} class={["conn-window", @window.failures > 0 && "is-unsteady"]}>
      <%= if @window.failures == 0 do %>
        {ngettext(
          "Steady for the last minute.",
          "Steady for the last %{count} minutes.",
          @window.minutes
        )}
        <span :if={@window.worst_ms}>
          {gettext("Slowest check %{ms} ms.", ms: @window.worst_ms)}
        </span>
      <% else %>
        <strong>
          {ngettext(
            "1 check failed in the last %{minutes} minutes.",
            "%{count} checks failed in the last %{minutes} minutes.",
            @window.failures,
            minutes: @window.minutes
          )}
        </strong>
        {gettext("It is answering now, but it has not been steady - worth a look at the network.")}
      <% end %>
    </p>
    """
  end

  # KB and MB rather than bytes: the reader is judging "is that a lot", and
  # 597,412 does not answer that faster than 583 KB. Binary units, because
  # that is what a disk and a body-size limit are measured in.
  defp bytes(n) when is_integer(n) and n < 1024, do: "#{n} B"

  defp bytes(n) when is_integer(n) and n < 1024 * 1024,
    do: "#{Float.round(n / 1024, 1)} KB"

  defp bytes(n) when is_integer(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  defp bytes(_not_a_number), do: nil

  defp pill_word(%{state: :connected, pending: pending}) when pending > 0,
    do: gettext("Sending")

  defp pill_word(%{state: :connected}), do: gettext("Live")
  defp pill_word(%{state: :refused}), do: gettext("Refused")
  defp pill_word(%{state: :unreachable}), do: gettext("Offline")
  defp pill_word(%{state: :unconfigured}), do: gettext("Not publishing")

  # The full sentence goes in the tooltip, so the short word above never has
  # to be the only explanation available.
  defp pill_title(%{state: :connected, pending: pending} = status) when pending > 0 do
    ngettext(
      "1 tournament waiting to send to %{host}",
      "%{count} tournaments waiting to send to %{host}",
      pending,
      host: host(status.endpoint || "")
    )
  end

  defp pill_title(%{state: :connected} = status) do
    gettext("Publishing to %{host} is working", host: host(status.endpoint || ""))
  end

  defp pill_title(status), do: status.message

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
