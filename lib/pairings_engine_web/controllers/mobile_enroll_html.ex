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
          <strong>Manubrium</strong> · Open<strong>Pairings</strong>
        </div>
        <h1>{gettext("Enter results")}</h1>
        <p class="mobile-sub">
          {gettext(
            "Scan the QR code your arbiter is showing, or type the code below. No account needed."
          )}
        </p>
        <%!-- iOS gives an app added to the home screen its own cookies, so a
              code redeemed in Safari does not come along. Installing first
              and typing the code in the app is the order that works on
              both. --%>
        <p class="mobile-sub" id="manubrium-install-hint">
          {gettext(
            "Tip: add this page to your home screen to get Manubrium as an app that keeps working when the wifi drops. On an iPhone, do that first and type the code in the app."
          )}
        </p>

        <p :if={@error} class="mobile-error" id="enroll-code-error" role="alert">{@error}</p>

        <form method="post" action={~p"/m"} class="mobile-form">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <label class="mobile-label" for="enroll-code">{gettext("Enrollment code")}</label>
          <input
            id="enroll-code"
            name="code"
            value={@code}
            inputmode="numeric"
            autocomplete="one-time-code"
            pattern="[0-9]*"
            maxlength="8"
            placeholder="12345678"
            autofocus
            class="mobile-code-input"
            aria-invalid={@error && "true"}
            aria-describedby={@error && "enroll-code-error"}
          />
          <button type="submit" class="mobile-btn">{gettext("Continue")}</button>
        </form>
      </main>
    </div>
    """
  end
end
