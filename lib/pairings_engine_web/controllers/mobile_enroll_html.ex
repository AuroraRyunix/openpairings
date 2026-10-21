defmodule PairingsEngineWeb.MobileEnrollHTML do
  @moduledoc "The mobile enrollment code-entry page (see MobileEnrollController)."
  use PairingsEngineWeb, :html

  def new(assigns) do
    ~H"""
    <div class="mobile-shell">
      <div class="mobile-header-actions mobile-header-actions--standalone">
        <Layouts.theme_switch />
      </div>
      <%!-- What this phone still had for the server when it was sent here
            (access ended, expired, left with a code still in force): shown,
            and sent if it can be, so it can be read out to the arbiter
            rather than vanish. Started by `app.js`; there is no LiveView. --%>
      <PairingsEngineWeb.Components.Manubrium.outbox standalone />

      <%!-- `<main>` for the root layout's skip link. The error is tied to the
            code box, so a screen reader hears it on the field it is about. --%>
      <main class="mobile-card" id="main-content" tabindex="-1">
        <div class="mobile-brand">
          <strong>Manubrium Lite</strong> · Open<strong>Pairings</strong>
        </div>
        <h1>{gettext("Enter results")}</h1>
        <p class="mobile-sub">
          {gettext(
            "Scan the QR code your arbiter is showing, or type the code below. No account needed."
          )}
        </p>
        <p :if={@error} class="mobile-error" id="enroll-code-error" role="alert">{@error}</p>

        <form method="post" action={~p"/m"} class="mobile-form" id="enroll-form">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <label class="mobile-label" for="enroll-code">
            {gettext("Code, or the link from the QR code")}
          </label>
          <input
            id="enroll-code"
            name="code"
            value={@code}
            autocomplete="one-time-code"
            autocapitalize="off"
            autocorrect="off"
            spellcheck="false"
            maxlength="300"
            placeholder="12345678"
            autofocus
            class="mobile-code-input"
            aria-invalid={@error && "true"}
            aria-describedby={@error && "enroll-code-error"}
          />
          <button type="submit" class="mobile-btn">{gettext("Continue")}</button>
        </form>

        <%!-- An arbiter with an account signs in instead, and what their
              phone enters is recorded under their name. Not on a desktop
              copy, which has no accounts but its owner's. --%>
        <p :if={not PairingsEngine.Authz.local_mode?()} class="mobile-sub" id="enroll-arbiter">
          <.link href={~p"/m/connect"}>{gettext("Arbiter with an account? Sign in instead")}</.link>
        </p>
      </main>
    </div>
    """
  end

  @doc """
  The page a scanned QR opens (`GET /m/e/:token`): who the code is for, one
  button, and the link again for an installed app on an iPhone, which has
  its own cookies and never sees what Safari was given.
  """
  def confirm(assigns) do
    ~H"""
    <div class="mobile-shell">
      <div class="mobile-header-actions mobile-header-actions--standalone">
        <Layouts.theme_switch />
      </div>

      <main class="mobile-card" id="main-content" tabindex="-1">
        <div class="mobile-brand">
          <strong>Manubrium Lite</strong> · Open<strong>Pairings</strong>
        </div>
        <h1>{@enrollment.tournament.name}</h1>
        <p class="mobile-sub" id="enroll-confirm-who">
          <%= if @enrollment.user do %>
            {gettext("Results and incidents as %{name}.",
              name: PairingsEngine.Accounts.User.display_label(@enrollment.user)
            )}
          <% else %>
            {gettext("Results for this tournament, without an account.")}
          <% end %>
        </p>

        <form
          method="post"
          action={~p"/m/e/#{@enrollment.token}"}
          class="mobile-form"
          id="enroll-confirm-form"
        >
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button type="submit" class="mobile-btn" id="enroll-confirm">
            {gettext("Connect this phone")}
          </button>
        </form>
      </main>
    </div>
    """
  end
end
