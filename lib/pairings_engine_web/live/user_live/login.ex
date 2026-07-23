defmodule PairingsEngineWeb.UserLive.Login do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
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

            <h1 class="auth-hero-title">Run world-class chess tournaments.</h1>

            <p class="auth-hero-sub">
              FIDE-compliant pairings, tie-breaks and norm reports — from the
              first round to the final crosstable, right in your browser.
            </p>

            <ul class="auth-features">
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                Invite co-arbiters — run one tournament together, live
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                Swiss (JaVaFo Dutch), round-robin & Keizer — all in one
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                FIDE C.07 tie-breaks & automatic title-norm judgment
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                Live standings, printing & public share links
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                TRF16, SWAR & PGN import / export
              </li>
            </ul>

            <div :if={!@current_scope} class="auth-hero-cta">
              <span>New to OpenPairings?</span>
              <.link navigate={~p"/users/register"} class="auth-hero-cta-btn">
                Create a free account <span aria-hidden="true">→</span>
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
                Re-authenticate to perform sensitive actions on your account.
              <% else %>
                New here? <.link navigate={~p"/users/register"} class="auth-link">Create an account</.link>.
              <% end %>
            </p>

            <div :if={local_mail_adapter?()} class="auth-notice">
              <.icon name="hero-information-circle" class="size-5 shrink-0" />
              <span>
                Local mail adapter — sent emails appear in <.link
                  href="/dev/mailbox"
                  class="auth-link"
                >the mailbox</.link>.
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
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <button type="submit" class="pe-btn primary auth-submit">
                Email me a magic link <span aria-hidden="true">→</span>
              </button>
            </.form>

            <div class="auth-divider"><span>or use a password</span></div>

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
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
              />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                autocomplete="current-password"
                spellcheck="false"
              />
              <button
                type="submit"
                class="pe-btn primary auth-submit"
                name={@form[:remember_me].name}
                value="true"
              >
                Log in and stay signed in <span aria-hidden="true">→</span>
              </button>
              <button type="submit" class="pe-btn auth-submit auth-submit-ghost">
                Log in only this time
              </button>
            </.form>
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

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:pairings_engine, PairingsEngine.Mailer)[:adapter] ==
      Swoosh.Adapters.Local
  end
end
