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

        <%!-- Worded here from the reason, never passed through from
              `Publishing`: see `detail/1` for why the sentence and the
              headline above it now come from the same place. --%>
        <p :if={not @compact} class="conn-detail">{detail(@status)}</p>

        <p class="conn-detail conn-facts">
          <span :if={@status.endpoint}>{host(@status.endpoint)}</span>
          <span :if={@status.pending > 0}>
            {ngettext(
              "1 tournament waiting to send",
              "%{count} tournaments waiting to send",
              @status.pending
            )}
          </span>
          <%!-- One phrase, not two. The size used to be bolted on as its own
                span, which read "last sent just now · 82.0 KB last sent" -
                the same words twice in one line. A snapshot is the whole
                tournament rather than a delta, so its size is the only
                figure that says what a round costs to publish, and it moves:
                the tie-break working multiplied it by ~3.4 on a large
                event. --%>
          <span :if={@status.pending == 0 and @status.last_published_at}>
            {sent_line(@status)}
          </span>
          <span :if={@status.pending == 0 and is_nil(@status.last_published_at)}>
            {gettext("nothing sent from this machine yet")}
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
        <%!-- One fact. This was three sentences - steady, slowest, and no
              drops since the app started - which is a paragraph to say
              "fine". The window is implied by naming it, and a drop is the
              only part worth a second clause, so it only appears when there
              has been one. --%>
        <span :if={@window.worst_ms}>
          {gettext("Slowest in %{minutes} min: %{ms} ms",
            minutes: @window.minutes,
            ms: @window.worst_ms
          )}
        </span>
        <span :if={@window.last_failure_at} class="conn-drop">
          {gettext("last drop %{ago}", ago: ago(@window.last_failure_at))}
        </span>
      <% else %>
        <%!-- Same shape as the steady line, and no advice: the colour and
              the number say it, and "check the network" is what somebody
              does about it rather than something this can tell them.
              The WINDOW stays in - two drops in ten minutes and two drops
              in a day are different facts, and a bare counter is neither. --%>
        <strong>
          {gettext("Drops in %{minutes} min: %{count}",
            minutes: @window.minutes,
            count: @window.failures
          )}
        </strong>
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

  defp pill_word(%{reason: {:refused, {:rejected, _status, "publishing_paused", _detail}}}),
    do: gettext("Paused")

  defp pill_word(%{state: :refused}), do: gettext("Refused")
  defp pill_word(%{state: :unreachable}), do: gettext("Offline")
  defp pill_word(%{reason: {:unconfigured, :consent_required}}), do: gettext("Waiting")
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

  defp pill_title(%{reason: _reason} = status), do: sentence(status)

  # The refusals OpenResults' contract says to show in red ("OpenPairings
  # desktop", the error table): each stops something until a person acts.
  # Everything else a server answers stays amber - it answered.
  @red_codes ~w(installation_suspended installation_revoked tournament_limit
                snapshot_too_large not_owner tournament_hidden address_blocked)

  # Amber while work is in flight, whatever the connection says: "connected,
  # and eight tournaments are still waiting" is not a green situation.
  defp tone(%{state: :connected, pending: pending}) when pending > 0, do: "busy"
  defp tone(%{state: :connected}), do: "ok"

  defp tone(%{state: :refused, reason: {:refused, rejection}} = status),
    do: if(red?(rejection, status[:mode]), do: "down", else: "refused")

  defp tone(%{state: :refused}), do: "refused"
  defp tone(%{state: :unreachable}), do: "down"
  # Waiting on the arbiter is not "off": something is switched on and has
  # not gone anywhere.
  defp tone(%{reason: {:unconfigured, :consent_required}}), do: "refused"
  defp tone(%{state: :unconfigured}), do: "off"

  defp red?({:rejected, _status, code, _detail}, _mode) when code in @red_codes, do: true
  # A token the server does not know is a wrong secret, amber, as it always
  # was. An installation key it does not know has stopped publishing.
  defp red?({:rejected, 401, nil, _detail}, :public), do: true
  defp red?({:rejected, _status, "unauthorized", _detail}, :public), do: true
  defp red?(_rejection, _mode), do: false

  defp headline(%{state: :connected, pending: pending}) when pending > 0, do: gettext("Sending")
  defp headline(%{state: :connected}), do: gettext("Connected")

  defp headline(%{reason: {:refused, {:rejected, _status, "publishing_paused", _detail}}}),
    do: gettext("Publishing paused")

  # Not "Token refused": in public mode there is no token to refuse.
  defp headline(%{state: :refused, mode: :public}), do: gettext("Refused by the results site")
  defp headline(%{state: :refused}), do: gettext("Token refused")
  defp headline(%{state: :unreachable}), do: gettext("Cannot reach the results site")

  defp headline(%{reason: {:unconfigured, :consent_required}}),
    do: gettext("Waiting for your go-ahead")

  defp headline(%{reason: {:unconfigured, :public_idle}}), do: gettext("Not publishing")
  defp headline(%{reason: {:unconfigured, :token_required}}), do: gettext("Needs a token")
  defp headline(%{state: :unconfigured}), do: gettext("Not set up")

  # "82 KB sent just now" rather than "last sent just now" beside "82.0 KB
  # last sent". When the size is not known yet - an installation that has
  # published from an older build - it falls back to the time alone rather
  # than inventing a number.
  defp sent_line(%{last_published_at: at} = status) do
    case bytes(status[:last_publish_bytes]) do
      nil -> gettext("last sent %{ago}", ago: ago(at))
      size -> gettext("%{size} sent %{ago}", size: size, ago: ago(at))
    end
  end

  @doc """
  What `PairingsEngine.Publishing.check/0` returned, as the sentence an
  arbiter reads - the result of the Test connection button on Connections.

  Standalone, so unlike the indicator's detail line it says "Connected" in
  its own words: nothing above it has said so already.
  """
  def describe_check(:ok), do: gettext("Connected. The address and token are both accepted.")
  def describe_check({:error, reason}), do: reason_sentence(reason)

  # The line under the headline.
  #
  # This used to be `Publishing`'s own English sentence, with the headline
  # stripped off the front by a regex when it repeated it: "Connected" above
  # "Connected. The address and token are both accepted." The headline was
  # translated and the sentence was not, so in Dutch the regex never matched
  # and the card read "Verbonden" above "Connected. The address and token are
  # both accepted." - the repetition the strip existed to remove, plus a
  # language switch mid-card. Both halves are worded here now, so the
  # sentence is simply written not to repeat the headline.
  #
  # "Sending" keeps the whole sentence, because there it is not a repeat:
  # the headline says the queue is moving, the sentence says the connection
  # under it is fine.
  defp detail(%{state: :connected, mode: :public, pending: pending}) when pending > 0,
    do: gettext("Connected. This computer publishes with a key of its own, no token needed.")

  defp detail(%{state: :connected, mode: :public}),
    do: gettext("This computer publishes with a key of its own, no token needed.")

  defp detail(%{state: :connected, pending: pending}) when pending > 0,
    do: gettext("Connected. The address and token are both accepted.")

  defp detail(%{state: :connected}), do: gettext("The address and token are both accepted.")
  defp detail(%{reason: _reason} = status), do: sentence(status)

  # The sentence for a status that is not "connected", in its mode's words.
  defp sentence(%{mode: :public, reason: reason}), do: describe_public(reason)
  defp sentence(%{reason: reason}), do: reason_sentence(reason)

  @doc """
  A public-mode reason as the sentence an arbiter reads - the Connections
  panel, the pill, and a tournament's Results site settings page, which
  passes the `limit` the server named (`PairingsEngine.Publishing.Failure`)
  so "the limit" can be a number.

  Differs from `describe_check/1` only where a token and an installation key
  mean different things; every server code shared by both modes is worded
  once, in `reason_sentence/1`.
  """
  def describe_public(reason, extras \\ %{})

  def describe_public({:refused, {:rejected, _status, "tournament_limit", _detail}}, %{
        limit: limit
      })
      when is_integer(limit),
      do:
        gettext(
          "This computer already has %{limit} tournaments on the results site, which is its limit. Publishing has stopped for this tournament.",
          limit: limit
        )

  def describe_public({:refused, {:rejected, _status, "snapshot_too_large", _detail}}, %{
        limit: limit
      })
      when is_integer(limit),
      do:
        gettext(
          "This tournament is too large for the results site, which accepts at most %{size}. Publishing has stopped for this tournament.",
          size: bytes(limit)
        )

  def describe_public({:refused, {:rejected, 401, nil, _detail}}, _extras),
    do: unrecognised_key_sentence()

  def describe_public({:refused, {:rejected, _status, "unauthorized", _detail}}, _extras),
    do: unrecognised_key_sentence()

  def describe_public(reason, _extras), do: reason_sentence(reason)

  defp unrecognised_key_sentence,
    do:
      gettext(
        "The results site does not recognise this computer's key. Publishing has stopped until you register again."
      )

  # One clause per `t:PairingsEngine.Publishing.check_failure/0`, each a whole
  # sentence that reads on its own and does not repeat the headline above it.
  #
  # An answer from the server is worded by its CODE - OpenResults' `error`
  # field, which is what its contract says to dispatch on - and by the status
  # only when there is no code. A code with no clause yet falls to the last
  # resort at the bottom and shows itself, rather than being passed off as
  # "not an OpenResults server", which a body carrying a code plainly is. So
  # a new code (`installation_revoked`, say) is one clause and one msgid here.
  defp reason_sentence({:unconfigured, :no_address}), do: gettext("No address is set.")
  defp reason_sentence({:unconfigured, :no_token}), do: gettext("No token is set.")

  defp reason_sentence({:refused, {:rejected, _status, "unauthorized", _detail}}),
    do: gettext("Reached the server, but it rejected the token.")

  defp reason_sentence({:refused, {:rejected, 401, nil, _detail}}),
    do: gettext("Reached the server, but it rejected the token.")

  # Public mode, nothing sent - see `t:PairingsEngine.Publishing.check_failure/0`.
  defp reason_sentence({:unconfigured, :public_idle}),
    do:
      gettext(
        "No tournament on this computer is being published, so nothing is sent to the results site."
      )

  defp reason_sentence({:unconfigured, :consent_required}),
    do:
      gettext(
        "Publishing is waiting for your go-ahead to register this computer with the results site. Nothing has been sent yet."
      )

  # The contract's "today's message" for a server that does not offer public
  # publishing: it needs a token from its operator.
  defp reason_sentence({:unconfigured, :token_required}),
    do:
      gettext("This results site only publishes tournaments sent with a token from its operator.")

  # OpenResults' public-publishing codes, one clause each - the contract's
  # desktop table. The limits are worded with their numbers in
  # `describe_public/2`, where the caller has them.
  defp reason_sentence({:refused, {:rejected, _status, "rate_limited", _detail}}),
    do:
      gettext("The results site asked this computer to wait a moment. It will try again shortly.")

  defp reason_sentence({:refused, {:rejected, _status, "publishing_paused", _detail}}),
    do:
      gettext(
        "The results site has paused publishing. Everything waiting is sent when it resumes."
      )

  defp reason_sentence({:refused, {:rejected, _status, "installation_suspended", _detail}}),
    do:
      gettext(
        "The results site has suspended this computer's key. Contact the operator of the results site."
      )

  defp reason_sentence({:refused, {:rejected, _status, "installation_revoked", _detail}}),
    do: gettext("The results site no longer accepts this computer's key. Publishing has stopped.")

  defp reason_sentence({:refused, {:rejected, _status, "tournament_limit", _detail}}),
    do:
      gettext(
        "This computer has reached the results site's limit on tournaments. Publishing has stopped for this tournament."
      )

  defp reason_sentence({:refused, {:rejected, _status, "snapshot_too_large", _detail}}),
    do:
      gettext(
        "This tournament is too large for the results site. Publishing has stopped for this tournament."
      )

  defp reason_sentence({:refused, {:rejected, _status, "not_owner", _detail}}),
    do:
      gettext(
        "A different installation owns this tournament on the results site. Ask the operator of the results site to transfer it to this computer."
      )

  # Not `not_owner`'s words: this installation does own it, and a moderator
  # of the results site took the page down (the contract, settled in the
  # build). Only the operator can undo that.
  defp reason_sentence({:refused, {:rejected, _status, "tournament_hidden", _detail}}),
    do:
      gettext(
        "The operator of the results site has hidden this tournament. Publishing has stopped for this tournament."
      )

  defp reason_sentence({:refused, {:rejected, _status, "registration_closed", _detail}}),
    do:
      gettext(
        "The results site is not accepting new installations right now. Nothing has been sent, and it will be tried again later."
      )

  defp reason_sentence({:refused, {:rejected, _status, "address_blocked", _detail}}),
    do:
      gettext(
        "The results site has blocked this computer's network address. Contact the operator of the results site."
      )

  defp reason_sentence({:refused, {:rejected, status, nil, _detail}}),
    do:
      gettext("Reached the server and it answered %{status}, which is not an OpenResults server.",
        status: status
      )

  defp reason_sentence({:unreachable, :timeout}), do: gettext("The connection timed out.")
  defp reason_sentence({:unreachable, :closed}), do: gettext("The connection was closed.")
  defp reason_sentence({:unreachable, :nxdomain}), do: gettext("The address did not resolve.")

  defp reason_sentence({:unreachable, :econnrefused}),
    do: gettext("The connection was refused - is the server running?")

  defp reason_sentence({:unreachable, other}),
    do: gettext("Could not connect (%{reason}).", reason: technical(other))

  # Last resort, for a reason or a server code with no sentence yet. This
  # renders in the top bar of every page, so a missing clause must not raise -
  # a crash here is every page down for as long as the reason persists. It is
  # deliberately technical, so the gap is visible rather than papered over.
  defp reason_sentence({_state, detail}),
    do: gettext("Could not confirm the connection (%{reason}).", reason: technical(detail))

  # The status and the server's code are what somebody can look up; the
  # server's `detail` is an English sentence meant for logs.
  defp technical({:rejected, status, code, _detail}) when is_binary(code), do: "#{status} #{code}"
  defp technical(error) when is_exception(error), do: Exception.message(error)
  defp technical(detail), do: inspect(detail)

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
