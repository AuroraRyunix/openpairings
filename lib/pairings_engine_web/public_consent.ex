defmodule PairingsEngineWeb.PublicConsent do
  @moduledoc """
  The consent dialog of public publishing, and what a page shows while a
  tournament waits on one of its steps.

  OpenResults' contract ("OpenPairings desktop", step 2): a desktop copy with
  no operator token asks the arbiter once per installation before it gets a
  key of its own, naming who runs the results site (or its host name when
  the server does not say) and linking its terms when there are any.
  Declining sends nothing and leaves publishing off.

  Two pages open it - a tournament's Results site settings, when publishing
  is turned on, and Connections, for "Register again" - so the socket half
  lives here and each page delegates three events and one `handle_async`:

      def handle_async(:public_server_info, result, socket),
        do: {:noreply, PublicConsent.received(socket, result)}

  ## Why the question is fetched, not assumed

  The dialog names the operator and links the terms, and only the server
  knows either. So opening it is `GET /api/server` - in a task, because a
  venue's wifi is exactly where this is clicked - and the modal says it is
  asking meanwhile. That GET is the one request made before the arbiter has
  agreed to anything, and it carries no credential.

  ## "Register again" is the same dialog

  After a revocation, the contract says never to register silently. The
  `:again` purpose is that deliberate act: the same question, a different
  button, and `Installation.start_over/1` instead of `give_consent/1`.
  """
  use PairingsEngineWeb, :html

  import Phoenix.LiveView, only: [start_async: 3]

  alias PairingsEngine.Publishing
  alias PairingsEngine.Publishing.{Failure, Installation}
  alias PairingsEngineWeb.Components.ConnectionStatus

  @type purpose :: :first | :again

  ## ---------- the socket half ----------

  @doc "Opens the dialog: asks the server who runs it, and shows that it is asking."
  @spec open(Phoenix.LiveView.Socket.t(), purpose()) :: Phoenix.LiveView.Socket.t()
  def open(socket, purpose) when purpose in [:first, :again] do
    socket
    |> assign(consent: {:loading, purpose})
    |> start_async(:public_server_info, fn -> Installation.server_info() end)
  end

  @doc """
  The server's answer, from the page's `handle_async/3`.

  A server that does not offer public publishing never gets the question:
  the dialog says it needs a token instead, which is what the contract calls
  today's message. A failure to ask at all - offline - is said as such, with
  a way to ask again.
  """
  def received(socket, result) do
    purpose =
      case socket.assigns[:consent] do
        {_stage, purpose} -> purpose
        {_stage, _detail, purpose} -> purpose
        _ -> :first
      end

    consent =
      case result do
        {:ok, {:ok, %{public_registration: "unavailable"}}} ->
          {:failed, {:unconfigured, :token_required}, purpose}

        {:ok, {:ok, %{public_publishing: "unavailable"}}} ->
          {:failed, {:unconfigured, :token_required}, purpose}

        {:ok, {:ok, %{} = info}} ->
          {:ask, info, purpose}

        {:ok, {:error, reason}} ->
          {:failed, reason, purpose}

        {:exit, _reason} ->
          {:failed, {:unreachable, :closed}, purpose}
      end

    assign(socket, consent: consent)
  end

  @doc """
  The arbiter agreed. Records it for this server and makes everything
  waiting due now; the drain registers, mints and publishes. Returns
  `{socket, info}` so the page can write its own audit row and flash.
  """
  def accept(socket) do
    case socket.assigns[:consent] do
      {:ask, info, purpose} ->
        case purpose do
          :first -> Installation.give_consent(info)
          :again -> Installation.start_over(info)
        end

        Publishing.retry_pending()
        {assign(socket, consent: nil), info, purpose}

      _ ->
        {assign(socket, consent: nil), nil, nil}
    end
  end

  @doc "Closes the dialog. Returns the purpose it was open for, or nil."
  def dismiss(socket) do
    purpose =
      case socket.assigns[:consent] do
        {_stage, purpose} -> purpose
        {_stage, _detail, purpose} -> purpose
        _ -> nil
      end

    {assign(socket, consent: nil), purpose}
  end

  ## ---------- the dialog ----------

  attr :consent, :any, required: true, doc: "nil, or the page's `@consent` assign"

  @doc "The modal. Renders nothing while `consent` is nil."
  def consent_dialog(%{consent: nil} = assigns), do: ~H""

  def consent_dialog(%{consent: {:loading, _purpose}} = assigns) do
    ~H"""
    <div class="pe-modal" id="public-consent" role="dialog" aria-modal="true">
      <div class="pe-modal-card">
        <div class="pe-modal-head">
          <h2>{gettext("Publishing on the results site")}</h2>
          <p>{gettext("Asking the results site who runs it...")}</p>
        </div>
      </div>
    </div>
    """
  end

  def consent_dialog(%{consent: {:failed, reason, purpose}} = assigns) do
    assigns = assign(assigns, reason: reason, purpose: purpose)

    ~H"""
    <div
      class="pe-modal"
      id="public-consent"
      role="dialog"
      aria-modal="true"
      phx-window-keydown="public_consent_decline"
      phx-key="escape"
    >
      <div class="pe-modal-card">
        <div class="pe-modal-head">
          <h2>{gettext("Publishing on the results site")}</h2>
          <p>{ConnectionStatus.describe_public(@reason)}</p>
        </div>
        <div class="pe-modal-body">
          <p :if={token_required?(@reason) and @purpose == :first} class="pe-modal-note">
            {gettext("Nothing was sent, and publishing is off again for this tournament.")}
          </p>
          <p :if={not token_required?(@reason) and @purpose == :first} class="pe-modal-note">
            {gettext(
              "Nothing has been sent. Publishing stays on for this tournament and waits for your go-ahead - try again when this computer is online."
            )}
          </p>
        </div>
        <div class="pe-modal-foot">
          <button type="button" class="pe-btn" phx-click="public_consent_decline">
            {gettext("Close")}
          </button>
          <button
            :if={not token_required?(@reason)}
            type="button"
            class="pe-btn primary"
            phx-click={
              if @purpose == :again, do: "public_register_again", else: "public_consent_open"
            }
          >
            {gettext("Try again")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  def consent_dialog(%{consent: {:ask, info, purpose}} = assigns) do
    assigns = assign(assigns, info: info, purpose: purpose)

    ~H"""
    <div
      class="pe-modal"
      id="public-consent"
      role="dialog"
      aria-modal="true"
      phx-window-keydown="public_consent_decline"
      phx-key="escape"
    >
      <div class="pe-modal-card">
        <div class="pe-modal-head">
          <h2>{gettext("Publish on %{host}?", host: @info.host)}</h2>
          <%!-- The contract: name the operator, or the host name when the
                server does not say who runs it. The host is in the title
                either way, so a null operator simply leaves this out. --%>
          <p :if={@info.operator}>
            {gettext("The results site at %{host} is run by %{operator}.",
              host: @info.host,
              operator: @info.operator
            )}
          </p>
        </div>
        <div class="pe-modal-body">
          <p :if={@purpose == :first}>
            {gettext(
              "This computer has not published there before. Without a token from the operator, it asks the results site once for a key of its own, and every tournament you publish from this computer uses that key."
            )}
          </p>
          <p :if={@purpose == :again}>
            {gettext(
              "This computer's old key is no longer accepted. Registering again asks the results site for a new one. Tournaments published under the old key stay where they are; the operator can move them to this computer."
            )}
          </p>
          <p>
            {gettext(
              "The results site then shows this tournament to anyone with its link - names, ratings, clubs, federations and results - under that operator's rules."
            )}
          </p>
          <p :if={@info.terms_url}>
            <.rich_text text={gettext("Read the %[terms] before you agree.")}>
              <:part name="terms">
                <a href={@info.terms_url} target="_blank" rel="noopener noreferrer">
                  {gettext("results site's terms")}
                </a>
              </:part>
            </.rich_text>
          </p>
          <p class="pe-modal-note">
            {gettext("Nothing is sent unless you agree. If you do not, publishing stays off.")}
          </p>
        </div>
        <div class="pe-modal-foot">
          <button type="button" class="pe-btn" phx-click="public_consent_decline">
            {if @purpose == :again, do: gettext("Cancel"), else: gettext("Do not publish")}
          </button>
          <button
            type="button"
            class="pe-btn primary pe-modal-go"
            phx-click="public_consent_accept"
          >
            {if @purpose == :again, do: gettext("Register again"), else: gettext("Agree and publish")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp token_required?({:unconfigured, :token_required}), do: true
  defp token_required?(_reason), do: false

  ## ---------- what is pending ----------

  attr :tournament, :map, required: true
  attr :state, :map, required: true, doc: "from `PairingsEngine.Publishing.public_state/1`"

  @doc """
  One tournament's place in public mode's steps, for its Results site
  settings page. Every step that has not happened yet is said in words, so
  "publishing is on" never looks like "published" while nothing has left -
  and a tournament with no link yet explains why there is no link.
  """
  def public_steps(%{state: %{step: :off}} = assigns), do: ~H""

  def public_steps(assigns) do
    ~H"""
    <div id="public-steps" class="set-field solo" style="margin-top: 12px">
      <%= case @state.step do %>
        <% :consent -> %>
          <p class="hint" style="margin: 0">
            {gettext(
              "Waiting for your go-ahead. Nothing has been sent to the results site yet, so there is no link."
            )}
          </p>
          <div class="actions" style="margin-top: 6px">
            <button type="button" class="pe-btn primary" phx-click="public_consent_open">
              {gettext("Continue")}
            </button>
          </div>
        <% :blocked -> %>
          <p style="margin: 0; color: var(--danger)">
            <strong>{ConnectionStatus.describe_public({:refused, @state.installation})}</strong>
          </p>
          <div class="actions" style="margin-top: 6px">
            <button
              :if={register_again?(@state.installation)}
              type="button"
              class="pe-btn primary"
              phx-click="public_register_again"
            >
              {gettext("Register again")}
            </button>
            <button
              :if={not register_again?(@state.installation)}
              type="button"
              class="pe-btn"
              phx-click="public_retry"
            >
              {gettext("Try again")}
            </button>
          </div>
        <% :register -> %>
          <p class="hint" style="margin: 0">
            {gettext("Waiting to register this computer with the results site. There is no link yet.")}
          </p>
        <% :mint -> %>
          <p class="hint" style="margin: 0">
            {gettext(
              "Waiting for the results site to create this tournament's address. Its link and QR code appear here once it has."
            )}
          </p>
        <% :send -> %>
          <p :if={not @state.stopped?} class="hint" style="margin: 0">
            {gettext("Waiting to send the latest changes to the results site.")}
          </p>
        <% :done -> %>
      <% end %>

      <%!-- A remembered refusal that does not stop anything - a pause, a
            suspension, registration closed - applies to every step. --%>
      <p
        :if={@state.step != :blocked and @state.installation}
        style={line_style(red?(@state.installation))}
        class={if red?(@state.installation), do: nil, else: "hint"}
      >
        {ConnectionStatus.describe_public({:refused, @state.installation})}
      </p>

      <%!-- The last failure of this tournament's queued publish. A rate limit
            is the one said only once it persists - the contract's "nothing
            unless it persists" - because the backoff answers it by itself. --%>
      <p
        :if={show_failure?(@state)}
        style={line_style(@state.stopped?)}
        class={if @state.stopped?, do: nil, else: "hint"}
      >
        {ConnectionStatus.describe_public(@state.failure.reason, %{limit: @state.failure.limit})}
      </p>

      <p
        :if={@state.stopped? and not_owner?(@state.failure)}
        class="hint"
        style="margin: 4px 0 0"
      >
        {gettext(
          "Give the operator this tournament's address, %{slug}, and this computer's installation, %{installation}.",
          slug: @tournament.public_slug,
          installation: @state.installation_id || "-"
        )}
      </p>

      <div :if={@state.stopped?} class="actions" style="margin-top: 6px">
        <button type="button" class="pe-btn" phx-click="public_retry">
          {gettext("Try again")}
        </button>
      </div>
    </div>
    """
  end

  defp line_style(true), do: "margin: 6px 0 0; color: var(--danger)"
  defp line_style(_), do: "margin: 6px 0 0"

  defp register_again?({:rejected, _status, code, _detail}),
    do: code in ["installation_revoked", "unauthorized"]

  defp register_again?(_), do: false

  defp red?({:rejected, _status, code, _detail}),
    do: code in ~w(installation_suspended installation_revoked unauthorized address_blocked)

  defp red?(_), do: false

  defp not_owner?(%Failure{reason: {:refused, {:rejected, _, "not_owner", _}}}), do: true
  defp not_owner?(_), do: false

  defp show_failure?(%{failure: nil}), do: false
  defp show_failure?(%{step: step}) when step in [:blocked, :consent, :done], do: false

  defp show_failure?(
         %{failure: %Failure{reason: {:refused, {:rejected, _, "rate_limited", _}}}} = state
       ),
       do: state.attempts >= 3

  # Already said once, by the installation-wide line above.
  defp show_failure?(%{
         failure: %Failure{reason: {:refused, rejection}},
         installation: installation
       })
       when not is_nil(installation) do
    Failure.effective_code(rejection) != Failure.effective_code(installation)
  end

  defp show_failure?(_state), do: true
end
