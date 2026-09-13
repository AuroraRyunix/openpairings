defmodule PairingsEngineWeb.UserLive.Login do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Accounts, RateLimit}
  alias PairingsEngineWeb.ClientIp

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
    >
      <div class="auth-wrap">
        <aside class="auth-hero">
          <div class="auth-hero-inner">
            <div class="auth-hero-brand">
              <svg
                class="auth-hero-mark"
                viewBox="0 0 64 48"
                xmlns="http://www.w3.org/2000/svg"
                aria-hidden="true"
              >
                <defs>
                  <linearGradient id="auth-orb" x1="0%" y1="0%" x2="100%" y2="100%">
                    <stop offset="0%" stop-color="#5fbf8f" />
                    <stop offset="100%" stop-color="#2e5e44" />
                  </linearGradient>
                </defs>
                <path
                  d="M22,18 Q10,10 1,14 Q8,22 10,30 Q16,32 22,30 Q26,26 22,18 Z"
                  fill="#f7f3e8"
                  stroke="#12150f"
                  stroke-width="3"
                  stroke-linejoin="round"
                />
                <path
                  d="M42,18 Q54,10 63,14 Q56,22 54,30 Q48,32 42,30 Q38,26 42,18 Z"
                  fill="#f7f3e8"
                  stroke="#12150f"
                  stroke-width="3"
                  stroke-linejoin="round"
                />
                <circle
                  cx="32"
                  cy="24"
                  r="14"
                  fill="url(#auth-orb)"
                  stroke="#12150f"
                  stroke-width="3"
                />
                <ellipse
                  cx="27"
                  cy="18"
                  rx="4"
                  ry="6"
                  fill="#ffffff"
                  opacity="0.5"
                  transform="rotate(-25 27 18)"
                />
              </svg>
              <span class="auth-hero-name">Open<strong>Pairings</strong></span>
            </div>

            <h1 class="auth-hero-title">{gettext("Run world-class chess tournaments.")}</h1>

            <p class="auth-hero-sub">
              {gettext(
                "Swiss pairings from our own engine, FIDE tie-break rules, and official report formats - from the first round to the final crosstable, right in your browser."
              )}
            </p>

            <ul class="auth-features">
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                {gettext("Invite co-arbiters · run one tournament together, live")}
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                {gettext("Swiss (Dutch), round-robin & Keizer")}
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                {gettext("Ainalrami · our own Swiss engine, built in Elixir")}
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                {gettext("FIDE C.07 tie-breaks & automatic title-norm judgment")}
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                {gettext("Live standings, printing & public share links")}
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                {gettext("TRF, SWAR & PGN import / export")}
              </li>
              <li class="auth-feature-soon">
                <.icon name="hero-clock-mini" class="size-5" />
                <span class="auth-feature-soon-tag">{gettext("Coming soon")}</span> TRF26
              </li>
            </ul>

            <div :if={!@current_scope} class="auth-hero-cta">
              <span>{gettext("New to OpenPairings?")}</span>
              <.link navigate={~p"/users/register"} class="auth-hero-cta-btn">
                {gettext("Create a free account")} <span aria-hidden="true">→</span>
              </.link>
            </div>
          </div>
        </aside>

        <div class="auth-panel">
          <div class="auth-card">
            <h2 class="auth-card-title">
              {if @current_scope, do: "Confirm it's you", else: "Welcome back"}
            </h2>
            <p class="auth-card-sub">
              <%= if @current_scope do %>
                {gettext("Re-authenticate to perform sensitive actions on your account.")}
              <% else %>
                {gettext("New here?")} <.link navigate={~p"/users/register"} class="auth-link">{gettext("Create an account")}</.link>.
              <% end %>
            </p>

            <div :if={local_mail_preview_adapter?() or console_mail_adapter?()} class="auth-notice">
              <.icon name="hero-information-circle" class="size-5 shrink-0" />
              <span :if={local_mail_preview_adapter?()}>
                <.rich_text text={gettext("Local mail adapter - sent emails appear in %[mailbox].")}>
                  <:part name="mailbox">
                    <.link href="/dev/mailbox" class="auth-link">{gettext("the mailbox")}</.link>
                  </:part>
                </.rich_text>
              </span>
              <span :if={console_mail_adapter?()}>
                {gettext(
                  "Local mode - sent emails are printed in this computer's terminal, not delivered."
                )}
              </span>
            </div>

            <.form
              :let={f}
              for={@form}
              id="login_form_magic"
              action={~p"/users/log-in"}
              phx-submit="submit_magic"
              class="auth-form"
            >
              <.input
                readonly={!!@current_scope}
                field={f[:email]}
                type="email"
                label={gettext("Email")}
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <button type="submit" class="pe-btn primary auth-submit">
                {gettext("Email me a magic link")} <span aria-hidden="true">→</span>
              </button>
            </.form>

            <%!-- Collapsed by default: magic-link is the one clear primary path,
                  not two equally-weighted full forms stacked on top of each
                  other. Plain `<details>` (same disclosure pattern the top bar's
                  "Advanced"/"Settings" menus already use) rather than LiveView
                  assign state - purely a show/hide, no server round-trip earns
                  its keep for that. --%>
            <details class="auth-password-toggle">
              <summary>{gettext("Use a password instead")}</summary>

              <.form
                :let={f}
                for={@form}
                id="login_form_password"
                action={~p"/users/log-in"}
                phx-submit="submit_password"
                phx-trigger-action={@trigger_submit}
                class="auth-form"
              >
                <.input
                  readonly={!!@current_scope}
                  field={f[:email]}
                  type="email"
                  label={gettext("Email")}
                  autocomplete="username"
                  spellcheck="false"
                  required
                />
                <.input
                  field={@form[:password]}
                  type="password"
                  label={gettext("Password")}
                  autocomplete="current-password"
                  spellcheck="false"
                />
                <button
                  type="submit"
                  class="pe-btn primary auth-submit"
                  name={@form[:remember_me].name}
                  value="true"
                >
                  {gettext("Log in and stay signed in")} <span aria-hidden="true">→</span>
                </button>
                <button type="submit" class="pe-btn auth-submit auth-submit-ghost">
                  {gettext("Log in only this time")}
                </button>
              </.form>
            </details>

            <div :if={PairingsEngine.Keycloak.configured?()} class="auth-divider">
              <span>or</span>
            </div>
            <%!-- 02cloud SSO (Keycloak / AD, auth.zerotwo.cloud) - see
                  KeycloakAuthController and docs/AGENTS.md. Hidden entirely
                  rather than shown-but-disabled when unconfigured (any dev
                  checkout, or a prod instance with no client registered yet),
                  since a login page with a dead button is worse than one
                  without it. --%>
            <.link
              :if={PairingsEngine.Keycloak.configured?()}
              href={~p"/auth/keycloak"}
              class="pe-btn auth-submit auth-sso"
              title={gettext("Sign in with 02cloud SSO")}
            >
              <.icon name="hero-building-office-2" class="size-4" /> {gettext("Sign in with SSO")}
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    # Connect info is readable only while mounting, so the address is captured
    # here for `handle_event("submit_magic", ...)` to rate-limit on.
    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       client_ip: ClientIp.from_socket(socket)
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if PairingsEngine.Accounts.User.sso_domain_email?(email) do
      # The SSO-only domain never gets a magic link. Some of these addresses
      # are synthesized from a directory username and have no mailbox at all,
      # so a link would silently go nowhere; the ones that DO have a mailbox
      # must still go through the directory rather than around it. Saying so
      # outright leaks nothing - the rule depends only on the domain, so the
      # response is identical for addresses that exist and ones that don't.
      {:noreply,
       socket
       |> put_flash(
         :error,
         "@#{PairingsEngine.Accounts.User.sso_domain()} accounts sign in with SSO."
       )
       |> push_navigate(to: ~p"/users/log-in")}
    else
      deliver_magic_link(socket, email)
    end
  end

  defp deliver_magic_link(socket, email) do
    # Counted per recipient AND per client: the first stops someone using this
    # form to bury one person's inbox in log-in links, the second stops one
    # client walking a list of addresses. Both are counted for every submit,
    # whether or not the address belongs to an account - a limit that only
    # applied to real users would answer "does this address exist?".
    limits = rate_limits(socket, email)

    if Enum.all?(limits, fn {bucket, key} -> RateLimit.allow?(bucket, key) end) do
      Enum.each(limits, fn {bucket, key} -> RateLimit.record(bucket, key) end)

      if user = Accounts.get_user_by_email(email) do
        # The flash below is deliberately identical whether this succeeds,
        # fails, or the address doesn't exist at all (see the comment on
        # `info`), so a failed send has to be logged here or it is invisible
        # everywhere: nothing raises, nothing is shown, and the person who
        # asked for a link just never gets one. `registration.ex`'s
        # `do_register/2` already logs the same underlying failure; this was
        # the one caller of `deliver_login_instructions/2` that didn't.
        case Accounts.deliver_login_instructions(
               user,
               &url(~p"/users/log-in/#{&1}")
             ) do
          {:ok, _email} ->
            :ok

          {:error, reason} ->
            require Logger
            Logger.error("Failed to send login instructions to #{user.email}: #{inspect(reason)}")
        end
      end

      info =
        "If your email is in our system, you will receive instructions for logging in shortly."

      {:noreply,
       socket
       |> put_flash(:info, info)
       |> push_navigate(to: ~p"/users/log-in")}
    else
      {:noreply,
       socket
       |> put_flash(
         :error,
         "That's a lot of log-in links. Check your inbox (and spam folder), " <>
           "then try again in a few minutes."
       )
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  # The address is normalized so casing/padding can't buy extra sends. A
  # client address is only available on a connected socket; when there is
  # none, the recipient key still applies.
  defp rate_limits(socket, email) do
    recipient = email |> to_string() |> String.trim() |> String.downcase()

    case socket.assigns[:client_ip] do
      nil -> [{:login_email, recipient}]
      ip -> [{:login_email, recipient}, {:login_client, ip}]
    end
  end

  # `Swoosh.Adapters.Local` is dev's preview mailbox (routed at /dev/mailbox,
  # only mounted when `dev_routes` is compiled in - see router.ex). That is a
  # DIFFERENT non-delivery mode from `PairingsEngine.ConsoleMailer`, which is
  # what `OPENPAIRINGS_LOCAL=1` / a Burrito build actually uses (see
  # config/runtime.exs and ConsoleMailer's moduledoc) - there is no
  # `/dev/mailbox` route at all in that build (`dev_routes` is compile-time
  # false there), so the two need different notices: one links to the
  # mailbox, the other says to look at the terminal. Before this,
  # `local_mail_adapter?/0` matched only the Local adapter, so a local/
  # desktop build showed NO notice at all on the paths ConsoleMailer's own
  # moduledoc says still send mail - a second account on the same machine,
  # an invited collaborator, a password reset - leaving someone who clicked
  # "email me a magic link" with no sign that anything happened.
  defp local_mail_preview_adapter?, do: mail_adapter() == Swoosh.Adapters.Local
  defp console_mail_adapter?, do: mail_adapter() == PairingsEngine.ConsoleMailer

  defp mail_adapter, do: Application.get_env(:pairings_engine, PairingsEngine.Mailer)[:adapter]
end
