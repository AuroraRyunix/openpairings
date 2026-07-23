defmodule PairingsEngineWeb.MobileEnrollHTML do
  @moduledoc "The mobile enrollment code-entry page (see MobileEnrollController)."
  use PairingsEngineWeb, :html

  def new(assigns) do
    ~H"""
    <div class="mobile-shell">
      <div class="mobile-card">
        <div class="mobile-brand">Open<strong>Pairings</strong></div>
        <h1>Enter results</h1>
        <p class="mobile-sub">
          Scan the QR code your arbiter is showing, or type the code below.
          No account needed.
        </p>

        <p :if={@error} class="mobile-error">{@error}</p>

        <form method="post" action={~p"/m"} class="mobile-form">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <label class="mobile-label" for="enroll-code">Enrollment code</label>
          <input
            id="enroll-code"
            name="code"
            value={@code}
            inputmode="numeric"
            autocomplete="one-time-code"
            pattern="[0-9]*"
            maxlength="6"
            placeholder="123456"
            autofocus
            class="mobile-code-input"
          />
          <button type="submit" class="mobile-btn">Continue</button>
        </form>
      </div>
    </div>
    """
  end
end
