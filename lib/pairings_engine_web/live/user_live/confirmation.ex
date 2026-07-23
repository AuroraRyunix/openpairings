defmodule PairingsEngineWeb.UserLive.Confirmation do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="auth-wrap auth-wrap-solo">
        <div class="auth-panel">
          <div class="auth-card">
            <h2 class="auth-card-title">Welcome back</h2>
            <p class="auth-card-sub">Signing in as <strong>{@user.email}</strong>.</p>

            <.form
              :if={!@user.confirmed_at}
              for={@form}
              id="confirmation_form"
              class="auth-form"
              phx-mounted={JS.focus_first()}
              phx-submit="submit"
              action={~p"/users/log-in?_action=confirmed"}
              phx-trigger-action={@trigger_submit}
            >
              <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
              <button
                type="submit"
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with="Confirming..."
                class="pe-btn primary auth-submit"
              >
                Confirm and stay signed in <span aria-hidden="true">→</span>
              </button>
              <button
                type="submit"
                phx-disable-with="Confirming..."
                class="pe-btn auth-submit auth-submit-ghost"
              >
                Confirm and sign in only this time
              </button>
            </.form>

            <.form
              :if={@user.confirmed_at}
              for={@form}
              id="login_form"
              class="auth-form"
              phx-submit="submit"
              phx-mounted={JS.focus_first()}
              action={~p"/users/log-in"}
              phx-trigger-action={@trigger_submit}
            >
              <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
              <%= if @current_scope do %>
                <button
                  type="submit"
                  phx-disable-with="Signing in..."
                  class="pe-btn primary auth-submit"
                >
                  Sign in <span aria-hidden="true">→</span>
                </button>
              <% else %>
                <button
                  type="submit"
                  name={@form[:remember_me].name}
                  value="true"
                  phx-disable-with="Signing in..."
                  class="pe-btn primary auth-submit"
                >
                  Keep me signed in on this device <span aria-hidden="true">→</span>
                </button>
                <button
                  type="submit"
                  phx-disable-with="Signing in..."
                  class="pe-btn auth-submit auth-submit-ghost"
                >
                  Sign in only this time
                </button>
              <% end %>
            </.form>

            <p :if={!@user.confirmed_at} class="auth-tools">
              Prefer passwords? You can enable one later in your user settings.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
