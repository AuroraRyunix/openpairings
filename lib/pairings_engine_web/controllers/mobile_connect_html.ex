defmodule PairingsEngineWeb.MobileConnectHTML do
  @moduledoc "The arbiter's own way onto Manubrium (see MobileConnectController)."
  use PairingsEngineWeb, :html

  alias PairingsEngine.Mobile

  def index(assigns) do
    ~H"""
    <div class="mobile-shell">
      <div class="mobile-header-actions mobile-header-actions--standalone">
        <Layouts.theme_switch />
      </div>

      <main class="mobile-card" id="main-content" tabindex="-1">
        <div class="mobile-brand">
          <strong>Manubrium</strong> · Open<strong>Pairings</strong>
        </div>
        <h1>{gettext("Your tournaments")}</h1>
        <p class="mobile-sub">
          {gettext("Results and incidents you enter from here are recorded under your own account.")}
        </p>

        <p
          :if={msg = Phoenix.Flash.get(@flash, :error)}
          class="mobile-error"
          id="connect-error"
          role="alert"
        >
          {msg}
        </p>

        <p :if={@tournaments == []} class="mobile-sub" id="connect-none">
          {gettext(
            "No tournament has made you an arbiter yet. Accept the invitation in the email first."
          )}
        </p>

        <ul class="connect-list" id="connect-tournaments">
          <li :for={{t, role} <- @tournaments} id={"connect-#{t.id}"} class="connect-item">
            <div class="connect-name">
              <strong>{t.name}</strong>
              <span class="connect-role">{role_label(role)}</span>
            </div>
            <form method="post" action={~p"/m/connect/#{t.id}"} id={"connect-here-#{t.id}"}>
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <button type="submit" class="mobile-btn">{gettext("Use this phone")}</button>
            </form>
            <form
              method="post"
              action={~p"/m/connect/#{t.id}/code"}
              id={"connect-code-#{t.id}"}
            >
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <button type="submit" class="mobile-btn mobile-btn--quiet">
                {gettext("Show a code for another phone")}
              </button>
            </form>
          </li>
        </ul>
      </main>
    </div>
    """
  end

  def code(assigns) do
    ~H"""
    <div class="mobile-shell">
      <div class="mobile-header-actions mobile-header-actions--standalone">
        <Layouts.theme_switch />
      </div>

      <main class="mobile-card" id="main-content" tabindex="-1">
        <div class="mobile-brand">
          <strong>Manubrium</strong> · Open<strong>Pairings</strong>
        </div>
        <h1>{@enrollment.tournament.name}</h1>
        <p class="mobile-sub">
          {gettext(
            "Scan this with your phone, or type the code at %{url}. It works once, for one phone, under your account.",
            url: url(~p"/m")
          )}
        </p>

        <div class="enroll-qr" id="connect-qr">
          <div
            class="enroll-qr-inner"
            role="img"
            aria-label={gettext("QR code for entering results on a phone")}
          >
            {Phoenix.HTML.raw(
              String.replace(Mobile.qr_svg(@link), "<svg", ~s(<svg aria-hidden="true"), global: false)
            )}
          </div>
        </div>

        <div class="enroll-code" id="connect-code">{@enrollment.code}</div>

        <input
          type="text"
          readonly
          value={@link}
          class="mobile-code-input mobile-link-input"
          aria-label={gettext("Link to paste into the app")}
          id="connect-link"
        />

        <p class="mobile-sub">
          <.link href={~p"/m/connect"}>{gettext("Back to your tournaments")}</.link>
        </p>
      </main>
    </div>
    """
  end

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:editor), do: gettext("Editor")
  defp role_label(:arbiter), do: gettext("Arbiter")
end
