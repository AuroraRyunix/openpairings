defmodule PairingsEngineWeb.UserLive.Registration do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Accounts, RateLimit}
  alias PairingsEngine.Accounts.User
  alias PairingsEngineWeb.ClientIp

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
                  <linearGradient id="reg-orb" x1="0%" y1="0%" x2="100%" y2="100%">
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
                <circle cx="32" cy="24" r="14" fill="url(#reg-orb)" stroke="#12150f" stroke-width="3" />
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

            <h1 class="auth-hero-title">Create your free account.</h1>

            <p class="auth-hero-sub">
              One account runs every event you organise - set up in seconds, no
              credit card, invite co-arbiters whenever you like.
            </p>

            <ul class="auth-features">
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                Swiss (JaVaFo Dutch), round-robin & Keizer &middot; all in one
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                FIDE C.07 tie-breaks & automatic title-norm judgment
              </li>
              <li>
                <.icon name="hero-check-circle-mini" class="size-5" />
                Live standings, printing & public share links
              </li>
            </ul>

            <div class="auth-hero-cta">
              <span>Already have an account?</span>
              <.link navigate={~p"/users/log-in"} class="auth-hero-cta-btn">
                Log in <span aria-hidden="true">→</span>
              </.link>
            </div>
          </div>
        </aside>

        <div class="auth-panel">
          <div class="auth-card">
            <h2 class="auth-card-title">Create an account</h2>
            <p class="auth-card-sub">
              Enter your email and we'll send a magic link to confirm it.
            </p>

            <.form
              for={@form}
              id="registration_form"
              class="auth-form"
              phx-submit="save"
              phx-change="validate"
            >
              <.input
                field={@form[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <button
                type="submit"
                phx-disable-with="Creating account..."
                class="pe-btn primary auth-submit"
              >
                Create a free account <span aria-hidden="true">→</span>
              </button>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: PairingsEngineWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    # Connect info is only readable while mounting; kept for the send limit in
    # `handle_event("save", ...)`. Registration will mail ANY address typed
    # here, so this endpoint needs the same throttle as the log-in form.
    {:ok,
     socket
     |> assign(client_ip: ClientIp.from_socket(socket))
     |> assign_form(changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    limits = rate_limits(socket, user_params["email"])

    if Enum.all?(limits, fn {bucket, key} -> RateLimit.allow?(bucket, key) end) do
      Enum.each(limits, fn {bucket, key} -> RateLimit.record(bucket, key) end)
      do_register(socket, user_params)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Too many sign-up emails from here just now. Try again in a few minutes."
       )}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp do_register(socket, user_params) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        case Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}")) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "An email was sent to #{user.email}, please access it to confirm your account."
             )
             |> push_navigate(to: ~p"/users/log-in")}

          {:error, reason} ->
            require Logger
            Logger.error("Failed to send login instructions to #{user.email}: #{inspect(reason)}")

            {:noreply,
             socket
             |> put_flash(
               :error,
               "Account created successfully, but we could not send the email. Please contact an admin or check your SMTP configuration."
             )
             |> push_navigate(to: ~p"/users/log-in")}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # Shares the `:login_email` bucket with the log-in form on purpose: both
  # send a magic link, so counting them together is what actually bounds how
  # much mail one address (or one client) can trigger.
  defp rate_limits(socket, email) do
    recipient = email |> to_string() |> String.trim() |> String.downcase()

    case socket.assigns[:client_ip] do
      nil -> [{:login_email, recipient}]
      ip -> [{:login_email, recipient}, {:login_client, ip}]
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
