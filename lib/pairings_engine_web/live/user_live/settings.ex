defmodule PairingsEngineWeb.UserLive.Settings do
  @moduledoc """
  The account page - `/users/settings`, and `/users/features`, which opens
  it at the federation switches. See docs/account.md.

  ## One page, in the order people look for things

  Profile, then signing in, then how the app looks, then what a new
  tournament starts with, then the federation packs, then the account's
  data, then deleting it. Each section is a card with a sentence saying
  what it is for, and the rail beside them (a row of chips on a phone)
  jumps between them. The cards reuse the Settings pages' own vocabulary -
  `.set-card`, a label above each control, the accent for the one action
  that matters - rather than inventing a second one.

  ## Recent sign-in is asked for per action, not for the page

  This page used to be `require_sudo_mode` as a whole: to look at it at all
  you re-typed your password if you had signed in more than ten minutes
  ago. That was right for the two things it held then (address and
  password) and absurd for most of what it holds now - nobody should prove
  who they are to switch on dark mode, which is also why the federation
  switches used to live on a page of their own.

  So the page is ordinary authentication, and the sections that can lock
  somebody out or carry data away - changing the address or the password,
  ending other sessions, downloading everything, deleting the account -
  each show a "Confirm it's you" panel instead of their controls until the
  account has signed in within the last twenty minutes
  (`Accounts.sudo_mode?/1`). Every one of their handlers checks again, and
  so does `PairingsEngineWeb.AccountController` for the two that leave the
  page, because a `phx-submit` payload is written by whoever holds the
  socket and a hidden control is not a gate.

  ## Three kinds of account

    * **Hosted, local sign-in** - everything.
    * **Hosted, 02cloud sign-in** for an address on the SSO domain
      (`User.sso_domain_email?/1`) - the address and the password belong to
      02cloud, and local password sign-in is refused for that domain
      anyway, so those two forms are replaced by a line saying so. Sessions,
      data and deletion work as for anyone.
    * **Local install** (`Authz.local_mode?/0`) - one owner, signed in by
      running the binary. Nothing here signs in, so the sign-in section and
      deleting the account are not shown; the download needs no recent
      sign-in because there is no sign-in to repeat. The account menu
      still links only `/users/features` there, as it always has.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [setting_toggle: 1, auto_publish_label: 1]

  alias PairingsEngine.{Accounts, Authz, Features, Publishing, RateLimit, RateOfPlay, Tournaments}
  alias PairingsEngine.Accounts.{Preferences, TournamentDefaults, User}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.{Locale, UserAgent, UserAuth}

  # Swatch colours for the accent choices - the light-theme `--accent` of
  # each, the same values the top-bar picker shows (`Layouts`' `@accents`).
  @accent_swatches %{
    "green" => "#2e5e44",
    "blue" => "#2160eb",
    "teal" => "#0d7870",
    "violet" => "#7c3aed",
    "rose" => "#be123c",
    "slate" => "#475569",
    "indigo" => "#4338ca",
    "cyan" => "#0e7490",
    "fuchsia" => "#a21caf"
  }

  ## ---------- mount ----------

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(
       page_title: gettext("Account"),
       local?: Authz.local_mode?(),
       current_token: session["user_token"],
       saved: nil,
       trigger_submit: false,
       delete_trigger: false,
       delete_confirm: ""
     )
     |> assign_user(user)
     |> assign_sessions()
     |> assign_data_counts()
     |> assign(delete_form: to_form(%{"confirm" => ""}, as: :account))}
  end

  # Everything derived from the account row, re-run after every save so the
  # page never shows a form bound to the row as it was before.
  #
  # The scope is rebuilt around the SAVED user so the layout sees the same
  # row, keeping `authenticated_at` - a virtual field, read from the session
  # token, which `Repo.update/1` hands back unchanged from the struct it was
  # given. Losing it would end sudo mode on the first save.
  defp assign_user(socket, %User{} = user) do
    scope = %{socket.assigns.current_scope | user: user}

    socket
    |> assign(
      current_scope: scope,
      user: user,
      sso_only?: User.sso_domain_email?(user.email),
      linked_sso?: User.sso?(user),
      has_password?: is_binary(user.hashed_password),
      enabled_features: Features.enabled(user),
      blockers: Accounts.account_deletion_blockers(user)
    )
    |> assign(
      profile_form: to_form(Accounts.change_user_profile(user)),
      email_form: to_form(Accounts.change_user_email(user, %{}, validate_unique: false)),
      password_form: to_form(Accounts.change_user_password(user, %{}, hash_password: false)),
      prefs_form: prefs_form(user),
      defaults_form: defaults_form(user.tournament_defaults, %{})
    )
  end

  defp prefs_form(user) do
    to_form(
      %{
        "locale" => user.locale || "",
        "theme" => user.theme || "",
        "accent" => user.accent || ""
      },
      as: :prefs
    )
  end

  defp defaults_form(defaults, params, action \\ nil) do
    (defaults || %TournamentDefaults{})
    |> TournamentDefaults.changeset(params)
    |> Map.put(:action, action)
    |> to_form(as: :defaults)
  end

  defp assign_sessions(socket) do
    sessions = Accounts.list_user_sessions(socket.assigns.user)

    assign(socket,
      sessions: sessions,
      other_sessions?: Enum.any?(sessions, &(not current?(&1, socket.assigns.current_token)))
    )
  end

  defp current?(session, current_token), do: session.token == current_token

  defp assign_data_counts(socket) do
    scope = socket.assigns.current_scope
    active = Enum.map(Tournaments.list_tournaments(scope), fn {t, _n, _own?} -> t end)
    archived = Enum.map(Tournaments.list_archived_tournaments(scope), fn {t, _own?} -> t end)
    binned = Tournaments.list_deleted_tournaments(scope)

    assign(socket,
      data_counts: %{active: length(active), archived: length(archived), binned: length(binned)},
      data_published?: Enum.any?(active ++ archived ++ binned, &Publishing.published?/1)
    )
  end

  ## ---------- recent sign-in ----------

  defp sudo?(socket), do: Accounts.sudo_mode?(socket.assigns.user)

  # The one refusal every guarded handler shares. The panel on the page is
  # already showing when this is reached from the page itself, so this
  # is for a stale tab - one opened while confirmed and used after.
  defp need_sudo(socket) do
    {:noreply,
     socket
     |> assign(saved: nil)
     |> put_flash(
       :error,
       gettext("Confirm it's you first - it has been a while since you signed in.")
     )}
  end

  ## ---------- profile ----------

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    form =
      socket.assigns.user
      |> Accounts.change_user_profile(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, profile_form: form, saved: nil)}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    case Accounts.update_user_profile(socket.assigns.user, params) do
      {:ok, user} ->
        {:noreply, socket |> assign_user(user) |> assign(saved: :profile)}

      {:error, changeset} ->
        {:noreply, assign(socket, profile_form: to_form(changeset, action: :update), saved: nil)}
    end
  end

  ## ---------- preferences ----------

  # Saved as it changes, like the federation switches: each control is one
  # choice with an obvious effect, and a Save button under three pickers
  # would only be a step to forget.
  def handle_event("save_preferences", %{"prefs" => params}, socket) do
    before = socket.assigns.user
    params = Map.take(params, ["locale", "theme", "accent"])

    case Accounts.update_user_preferences(before, params) do
      {:ok, user} ->
        socket =
          socket
          |> assign_user(user)
          |> assign(saved: :preferences)
          |> push_appearance(before, user)

        # A new language needs a page load: the session holds the language
        # and `Plugs.AccountLocale` puts the account's into it on the next
        # request. Back to this section, in the new language.
        if user.locale && user.locale != before.locale do
          {:noreply, redirect(socket, to: ~p"/users/settings" <> "#preferences")}
        else
          {:noreply, socket}
        end

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(prefs_form: prefs_form(before), saved: nil)
         |> put_flash(:error, gettext("Could not save that. Please try again."))}
    end
  end

  ## ---------- new tournaments ----------

  def handle_event("validate_defaults", %{"defaults" => params}, socket) do
    {:noreply,
     assign(socket,
       defaults_form: defaults_form(socket.assigns.user.tournament_defaults, params, :validate),
       saved: nil
     )}
  end

  def handle_event("save_defaults", %{"defaults" => params}, socket) do
    case Accounts.update_tournament_defaults(socket.assigns.user, params) do
      {:ok, user} ->
        {:noreply, socket |> assign_user(user) |> assign(saved: :defaults)}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           defaults_form: defaults_form(socket.assigns.user.tournament_defaults, params, :update),
           saved: nil
         )}
    end
  end

  def handle_event("clear_defaults", _params, socket) do
    empty = Map.new(TournamentDefaults.fields(), &{Atom.to_string(&1), ""})

    case Accounts.update_tournament_defaults(socket.assigns.user, empty) do
      {:ok, user} -> {:noreply, socket |> assign_user(user) |> assign(saved: :defaults)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  ## ---------- federation features ----------

  # The form submits the complete set every time - every switch is present,
  # each with the hidden `value="false"` companion `setting_toggle/1` emits -
  # so this is a replace and never a merge. Two tabs open on this page cannot
  # produce a half-applied state; the later save simply wins, which is what
  # a checkbox is understood to do. The gates that matter live at the
  # controls these keys switch on - see `PairingsEngine.Features`.
  def handle_event("save_features", params, socket) do
    keys =
      params
      |> Map.get("feature", %{})
      |> Enum.filter(fn {_key, value} -> value == "true" end)
      |> Enum.map(fn {key, _value} -> key end)

    case Features.set_enabled(socket.assigns.user, keys) do
      {:ok, user} ->
        {:noreply, socket |> assign_user(user) |> assign(saved: :features)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save that. Please try again."))}
    end
  end

  ## ---------- email ----------

  def handle_event("validate_email", %{"user" => params}, socket) do
    form =
      socket.assigns.user
      |> Accounts.change_user_email(params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: form, saved: nil)}
  end

  def handle_event("update_email", %{"user" => params}, socket) do
    user = socket.assigns.user
    key = Integer.to_string(user.id)

    cond do
      socket.assigns.local? or socket.assigns.sso_only? ->
        {:noreply, socket}

      not sudo?(socket) ->
        need_sudo(socket)

      not RateLimit.allow?(:email_change, key) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Several confirmation links went out just now. Try again in an hour.")
         )}

      true ->
        case Accounts.change_user_email(user, params) do
          %{valid?: true} = changeset ->
            RateLimit.record(:email_change, key)
            applied_user = Ecto.Changeset.apply_action!(changeset, :insert)
            send_email_confirmation(socket, user, applied_user)

          changeset ->
            {:noreply, assign(socket, email_form: to_form(changeset, action: :insert))}
        end
    end
  end

  ## ---------- password ----------

  def handle_event("validate_password", %{"user" => params}, socket) do
    form =
      socket.assigns.user
      |> Accounts.change_user_password(params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: form, saved: nil)}
  end

  # Validated here, then submitted to `/users/update-password` for real
  # (`phx-trigger-action`): changing the password ends every session,
  # including this one, and only a controller can hand the browser the new
  # session cookie.
  def handle_event("update_password", %{"user" => params}, socket) do
    cond do
      socket.assigns.local? or socket.assigns.sso_only? ->
        {:noreply, socket}

      not sudo?(socket) ->
        need_sudo(socket)

      true ->
        case Accounts.change_user_password(socket.assigns.user, params) do
          %{valid?: true} = changeset ->
            {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

          changeset ->
            {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
        end
    end
  end

  ## ---------- sessions ----------

  def handle_event("revoke_session", %{"id" => id}, socket) do
    current = Enum.find(socket.assigns.sessions, &current?(&1, socket.assigns.current_token))

    cond do
      socket.assigns.local? ->
        {:noreply, socket}

      not sudo?(socket) ->
        need_sudo(socket)

      current && to_string(current.id) == to_string(id) ->
        {:noreply,
         put_flash(socket, :error, gettext("That is this browser - use Log out to end it."))}

      true ->
        case Accounts.delete_user_session(socket.assigns.user, id) do
          {:ok, token} ->
            UserAuth.disconnect_sessions([token])

            {:noreply,
             socket
             |> assign_sessions()
             |> assign(saved: :sessions)
             |> put_flash(:info, gettext("That session has been signed out."))}

          {:error, _} ->
            {:noreply, assign_sessions(socket)}
        end
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    cond do
      socket.assigns.local? or is_nil(socket.assigns.current_token) ->
        {:noreply, socket}

      not sudo?(socket) ->
        need_sudo(socket)

      true ->
        {:ok, tokens} =
          Accounts.delete_other_user_sessions(socket.assigns.user, socket.assigns.current_token)

        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> assign_sessions()
         |> assign(saved: :sessions)
         |> put_flash(
           :info,
           ngettext(
             "Signed out of %{count} other session.",
             "Signed out of %{count} other sessions.",
             length(tokens)
           )
         )}
    end
  end

  ## ---------- deleting the account ----------

  def handle_event("delete_input", %{"account" => %{"confirm" => confirm}}, socket) do
    {:noreply,
     assign(socket,
       delete_confirm: confirm,
       delete_form: to_form(%{"confirm" => confirm}, as: :account)
     )}
  end

  # Checked here so the page can say what is wrong without a round trip,
  # then submitted to `AccountController.delete/2`, which checks all of it
  # again - it is the one that deletes, and it cannot trust this page.
  def handle_event("delete_account", %{"account" => %{"confirm" => confirm}}, socket) do
    user = socket.assigns.user
    blockers = Accounts.account_deletion_blockers(user)

    cond do
      socket.assigns.local? ->
        {:noreply, socket}

      not sudo?(socket) ->
        need_sudo(socket)

      blockers != [] ->
        {:noreply, assign(socket, blockers: blockers)}

      not Accounts.account_deletion_confirmed?(user, confirm) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Type your email address exactly to delete the account.")
         )}

      true ->
        {:noreply, assign(socket, delete_trigger: true, delete_confirm: confirm)}
    end
  end

  # Applies a newly stored theme or accent in this browser straight away,
  # through the same code path the top-bar pickers use (see
  # `pe:apply-appearance` in assets/js/app.js). Only what changed, and only
  # a real value: "each device decides" leaves this device as it is.
  defp push_appearance(socket, before, user) do
    changes =
      [:theme, :accent]
      |> Enum.map(&{&1, Map.get(user, &1)})
      |> Enum.filter(fn {key, value} -> is_binary(value) and value != Map.get(before, key) end)
      |> Map.new()

    if changes == %{}, do: socket, else: push_event(socket, "pe:apply-appearance", changes)
  end

  # The send result used to be discarded here, so a failed send (an SMTP
  # hiccup, same as the collaborator-invite mailer) still showed "A link ...
  # has been sent". There is no enumeration concern in telling a signed-in
  # person about their own account, so a failure says so.
  defp send_email_confirmation(socket, user, applied_user) do
    case Accounts.deliver_user_update_email_instructions(
           applied_user,
           user.email,
           &url(~p"/users/settings/confirm-email/#{&1}")
         ) do
      {:ok, _email} ->
        {:noreply,
         socket
         |> assign(saved: :email)
         |> put_flash(
           :info,
           gettext("A link to confirm your email change has been sent to the new address.")
         )}

      {:error, reason} ->
        require Logger

        Logger.error(
          "Failed to send update-email instructions to #{applied_user.email}: #{inspect(reason)}"
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("We could not send the confirmation email. Please try again shortly.")
         )}
    end
  end

  ## ---------- render ----------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, sudo?: Accounts.sudo_mode?(assigns.user))

    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      active="features"
    >
      <div class="acct-page">
        <header class="acct-header">
          <span class="acct-avatar" aria-hidden="true">{initials(@user)}</span>
          <div class="acct-identity">
            <h1>{gettext("Account")}</h1>
            <p class="acct-who">
              <span :if={@user.display_name} class="acct-who-name">{@user.display_name}</span>
              <span class="acct-who-email">{@user.email}</span>
            </p>
            <div class="acct-tags">
              <span :if={@linked_sso?} class="badge" id="acct-sso-badge">
                {gettext("Signed in with 02cloud")}
              </span>
              <span :if={User.role(@user) != :owner} class="badge muted">{role_label(@user)}</span>
              <span :if={@local?} class="badge muted">{gettext("This computer")}</span>
            </div>
          </div>
        </header>

        <div class="acct-layout">
          <nav class="acct-nav" aria-label={gettext("Account sections")}>
            <a href="#profile"><.icon name="hero-user-micro" class="size-4" /> {gettext("Profile")}</a>
            <a :if={!@local?} href="#security">
              <.icon name="hero-shield-check-micro" class="size-4" /> {gettext("Sign-in & security")}
            </a>
            <a href="#preferences">
              <.icon name="hero-swatch-micro" class="size-4" /> {gettext("Preferences")}
            </a>
            <a href="#new-tournaments">
              <.icon name="hero-plus-circle-micro" class="size-4" /> {gettext("New tournaments")}
            </a>
            <a href="#features">
              <.icon name="hero-flag-micro" class="size-4" /> {gettext("Federation features")}
            </a>
            <a href="#your-data">
              <.icon name="hero-arrow-down-tray-micro" class="size-4" /> {gettext("Your data")}
            </a>
            <a :if={!@local?} href="#delete-account" class="acct-nav-danger">
              <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete account")}
            </a>
          </nav>

          <div class="acct-main">
            <%!-- ============ Profile ============ --%>
            <section id="profile" class="set-card acct-section" aria-labelledby="profile-title">
              <div class="acct-section-head">
                <div>
                  <h2 id="profile-title">{gettext("Profile")}</h2>
                  <p class="hint">
                    {gettext(
                      "How you appear to the people you share tournaments with: in the audit log, the history, the sharing list and the invitations you send."
                    )}
                  </p>
                </div>
              </div>

              <.form
                for={@profile_form}
                id="profile-form"
                phx-change="validate_profile"
                phx-submit="save_profile"
              >
                <.input
                  field={@profile_form[:display_name]}
                  type="text"
                  label={gettext("Display name")}
                  placeholder={gettext("e.g. Jan Peeters")}
                  maxlength="80"
                  autocomplete="name"
                />
                <p class="hint acct-field-hint">
                  {gettext("Leave it empty to show your email address instead.")}
                </p>
                <div class="acct-actions">
                  <button type="submit" class="pe-btn primary" phx-disable-with={gettext("Saving...")}>
                    {gettext("Save profile")}
                  </button>
                  <.saved :if={@saved == :profile} id="profile-saved" />
                </div>
              </.form>
            </section>

            <%!-- ============ Sign-in & security ============ --%>
            <section
              :if={!@local?}
              id="security"
              class="set-card acct-section"
              aria-labelledby="security-title"
            >
              <div class="acct-section-head">
                <div>
                  <h2 id="security-title">{gettext("Sign-in & security")}</h2>
                  <p class="hint">
                    {gettext(
                      "Your address, your password, and every browser that is signed in to this account."
                    )}
                  </p>
                </div>
              </div>

              <.sudo_panel
                :if={!@sudo?}
                id="security-locked"
                text={
                  gettext(
                    "Changing your address or password and signing other browsers out ask you to confirm it's you first, because you signed in a while ago."
                  )
                }
              />

              <%= if @sso_only? do %>
                <div class="acct-sso" id="acct-sso-managed">
                  <.icon name="hero-building-office-2" class="size-5 acct-sso-icon" />
                  <div>
                    <strong>{gettext("Signed in with 02cloud")}</strong>
                    <p class="hint">
                      {gettext(
                        "Your address (%{email}) and your password are managed by 02cloud. Change them there; this account follows.",
                        email: @user.email
                      )}
                    </p>
                  </div>
                </div>
              <% else %>
                <div class="acct-sub acct-sub-first">
                  <h3>{gettext("Email address")}</h3>
                  <p class="hint">
                    <.rich_text text={gettext("You sign in as %[email].")}>
                      <:part name="email"><strong>{@user.email}</strong></:part>
                    </.rich_text>
                    {gettext("A new address takes effect once you click the link we send to it.")}
                  </p>
                  <p :if={@linked_sso?} class="hint">
                    {gettext("This account is also linked to 02cloud sign-in, which keeps working.")}
                  </p>

                  <.form
                    :if={@sudo?}
                    for={@email_form}
                    id="email_form"
                    phx-submit="update_email"
                    phx-change="validate_email"
                  >
                    <.input
                      field={@email_form[:email]}
                      type="email"
                      label={gettext("New email address")}
                      autocomplete="username"
                      spellcheck="false"
                      required
                    />
                    <div class="acct-actions">
                      <button
                        type="submit"
                        class="pe-btn primary"
                        phx-disable-with={gettext("Changing...")}
                      >
                        {gettext("Change Email")}
                      </button>
                      <.saved :if={@saved == :email} id="email-saved" text={gettext("Link sent")} />
                    </div>
                  </.form>
                </div>

                <div class="acct-sub">
                  <h3>
                    {if @has_password?, do: gettext("Password"), else: gettext("Set a password")}
                  </h3>
                  <p class="hint">
                    {if @has_password?,
                      do:
                        gettext(
                          "At least 12 characters. Changing it signs every other browser out, including this one for a moment."
                        ),
                      else:
                        gettext(
                          "You sign in with an email link. A password lets you sign in without waiting for one. At least 12 characters."
                        )}
                  </p>

                  <.form
                    :if={@sudo?}
                    for={@password_form}
                    id="password_form"
                    action={~p"/users/update-password"}
                    method="post"
                    phx-change="validate_password"
                    phx-submit="update_password"
                    phx-trigger-action={@trigger_submit}
                  >
                    <input
                      name={@password_form[:email].name}
                      type="hidden"
                      id="hidden_user_email"
                      spellcheck="false"
                      value={@user.email}
                    />
                    <div class="acct-grid">
                      <.input
                        field={@password_form[:password]}
                        type="password"
                        label={gettext("New password")}
                        autocomplete="new-password"
                        spellcheck="false"
                        required
                      />
                      <.input
                        field={@password_form[:password_confirmation]}
                        type="password"
                        label={gettext("Confirm new password")}
                        autocomplete="new-password"
                        spellcheck="false"
                      />
                    </div>
                    <div class="acct-actions">
                      <button
                        type="submit"
                        class="pe-btn primary"
                        phx-disable-with={gettext("Saving...")}
                      >
                        {gettext("Save Password")}
                      </button>
                    </div>
                  </.form>
                </div>
              <% end %>

              <div class="acct-sub" id="sessions">
                <div class="acct-sub-head">
                  <div>
                    <h3>{gettext("Where you're signed in")}</h3>
                    <p class="hint">
                      {gettext(
                        "Every browser that can open this account without signing in again. Sign out any you don't recognise, or a computer you have finished with."
                      )}
                    </p>
                  </div>
                  <button
                    :if={@sudo? and @other_sessions?}
                    type="button"
                    id="revoke-other-sessions"
                    class="pe-btn"
                    phx-click="revoke_other_sessions"
                    data-confirm={gettext("Sign out every other browser? This one stays signed in.")}
                  >
                    {gettext("Sign out everywhere else")}
                  </button>
                </div>

                <ul class="acct-sessions" id="session-list">
                  <li
                    :for={s <- @sessions}
                    id={"session-#{s.id}"}
                    class={["acct-session", current?(s, @current_token) && "is-current"]}
                  >
                    <.icon name={device_icon(s.user_agent)} class="size-5 acct-session-icon" />
                    <div class="acct-session-text">
                      <span class="acct-session-name">{device_label(s.user_agent)}</span>
                      <span
                        class="acct-session-meta"
                        title={
                          Calendar.strftime(s.authenticated_at || s.inserted_at, "%Y-%m-%d %H:%M UTC")
                        }
                      >
                        {signed_in_label(s.authenticated_at || s.inserted_at)}
                      </span>
                    </div>
                    <span :if={current?(s, @current_token)} class="badge">{gettext("This browser")}</span>
                    <button
                      :if={@sudo? and not current?(s, @current_token)}
                      type="button"
                      class="pe-btn danger-link"
                      id={"revoke-session-#{s.id}"}
                      phx-click="revoke_session"
                      phx-value-id={s.id}
                    >
                      {gettext("Sign out")}
                    </button>
                  </li>
                </ul>
                <.saved :if={@saved == :sessions} id="sessions-saved" />
              </div>
            </section>

            <%!-- ============ Preferences ============ --%>
            <section
              id="preferences"
              class="set-card acct-section"
              aria-labelledby="preferences-title"
            >
              <div class="acct-section-head">
                <div>
                  <h2 id="preferences-title">{gettext("Preferences")}</h2>
                  <p class="hint">
                    {gettext(
                      "Stored on your account, so they follow you to every computer you sign in on. Saved as you choose."
                    )}
                  </p>
                </div>
                <.saved :if={@saved == :preferences} id="preferences-saved" />
              </div>

              <.form for={@prefs_form} id="preferences-form" phx-change="save_preferences">
                <.input
                  :if={length(Locale.locales()) > 1}
                  field={@prefs_form[:locale]}
                  type="select"
                  label={gettext("Language")}
                  options={locale_options()}
                />
                <p :if={length(Locale.locales()) > 1} class="hint acct-field-hint">
                  {gettext(
                    "The language picker in the top bar changes this too. \"Automatic\" uses whatever each browser asks for."
                  )}
                </p>

                <fieldset class="acct-choice-group" id="theme-choices">
                  <legend>{gettext("Colour theme")}</legend>
                  <div class="acct-choices">
                    <label :for={{value, label} <- theme_options()} class="acct-choice">
                      <input
                        type="radio"
                        name="prefs[theme]"
                        value={value}
                        checked={(@user.theme || "") == value}
                      />
                      <span>{label}</span>
                    </label>
                  </div>
                </fieldset>

                <fieldset class="acct-choice-group" id="accent-choices">
                  <legend>{gettext("Accent colour")}</legend>
                  <div class="acct-choices">
                    <label :for={{value, label} <- accent_options()} class="acct-choice">
                      <input
                        type="radio"
                        name="prefs[accent]"
                        value={value}
                        checked={(@user.accent || "") == value}
                      />
                      <span
                        :if={value != ""}
                        class="acct-swatch"
                        style={"--swatch: #{Map.fetch!(accent_swatches(), value)}"}
                        aria-hidden="true"
                      ></span>
                      <span>{label}</span>
                    </label>
                  </div>
                </fieldset>

                <p class="hint acct-field-hint">
                  {gettext(
                    "\"This device decides\" leaves each browser with the theme and accent picked in its own top bar. Choose one here to use it everywhere; the top-bar pickers then change it everywhere too."
                  )}
                </p>
              </.form>
            </section>

            <%!-- ============ New tournaments ============ --%>
            <section
              id="new-tournaments"
              class="set-card acct-section"
              aria-labelledby="new-tournaments-title"
            >
              <div class="acct-section-head">
                <div>
                  <h2 id="new-tournaments-title">{gettext("New tournaments")}</h2>
                  <p class="hint">
                    {gettext(
                      "What \"New tournament\" starts with, so a club that runs the same event every week doesn't type it every week. Leave a field empty to keep the usual default. Existing tournaments and imports are not affected."
                    )}
                  </p>
                </div>
              </div>

              <.form
                for={@defaults_form}
                id="defaults-form"
                phx-change="validate_defaults"
                phx-submit="save_defaults"
              >
                <div class="acct-grid">
                  <.input
                    field={@defaults_form[:pairing_system]}
                    type="select"
                    label={gettext("Pairing system")}
                    prompt={gettext("Usual default (Swiss)")}
                    options={pairing_system_options()}
                  />
                  <.input
                    field={@defaults_form[:rounds_count]}
                    type="number"
                    label={gettext("Rounds")}
                    placeholder="9"
                    min="1"
                    max={Tournament.max_rounds()}
                  />
                  <.input
                    field={@defaults_form[:standard]}
                    type="select"
                    label={gettext("Format")}
                    prompt={gettext("Usual default (Standard)")}
                    options={standard_options()}
                  />
                  <.input
                    field={@defaults_form[:rate_of_play]}
                    type="select"
                    label={gettext("Rate of play")}
                    options={
                      rate_of_play_options(
                        @defaults_form[:standard].value,
                        @defaults_form[:rate_of_play].value
                      )
                    }
                  />
                  <.input
                    field={@defaults_form[:city]}
                    type="text"
                    label={gettext("Place")}
                    placeholder={gettext("e.g. Gent")}
                  />
                  <.input
                    field={@defaults_form[:federation]}
                    type="text"
                    label={gettext("Federation")}
                    placeholder="BEL"
                    maxlength="3"
                    autocomplete="off"
                    class="w-full input acct-upper"
                  />
                  <.input
                    field={@defaults_form[:organizer]}
                    type="text"
                    label={gettext("Organizer")}
                  />
                  <.input
                    field={@defaults_form[:publish_mode]}
                    type="select"
                    label={gettext("Publish automatically")}
                    prompt={gettext("Usual default (by hand)")}
                    options={publish_mode_options()}
                  />
                  <.input
                    :if={@defaults_form[:publish_mode].value in ~w(pairings results standings)}
                    field={@defaults_form[:publish_delay_minutes]}
                    type="number"
                    label={gettext("Pairings after (minutes)")}
                    min="0"
                  />
                </div>

                <p
                  :if={@defaults_form[:publish_mode].value in ~w(pairings results standings)}
                  class="error-note"
                >
                  <strong>{gettext("Rounds go public without you pressing anything.")}</strong>
                  {gettext(
                    "With no delay the field sees a pairing at the same moment you do. You can always take a round back down on the Pairings page."
                  )}
                </p>

                <div class="acct-actions">
                  <button type="submit" class="pe-btn primary" phx-disable-with={gettext("Saving...")}>
                    {gettext("Save defaults")}
                  </button>
                  <button
                    :if={TournamentDefaults.any?(@user.tournament_defaults)}
                    type="button"
                    id="clear-defaults"
                    class="pe-btn"
                    phx-click="clear_defaults"
                  >
                    {gettext("Clear all")}
                  </button>
                  <.saved :if={@saved == :defaults} id="defaults-saved" />
                </div>
              </.form>
            </section>

            <%!-- ============ Federation features ============ --%>
            <section
              id="features"
              class="set-card acct-section"
              tabindex="-1"
              aria-labelledby="features-title"
              phx-mounted={@live_action == :features && JS.focus()}
            >
              <div class="acct-section-head">
                <div>
                  <h2 id="features-title">{gettext("Federation features")}</h2>
                  <p class="hint">
                    {gettext(
                      "Some national federations have their own member list, their own file format, and their own habits. Switch on the ones you work with; leave the rest off and they stay out of your way."
                    )}
                  </p>
                </div>
                <.saved :if={@saved == :features} id="features-saved" />
              </div>

              <div class="acct-note">
                <strong>{gettext("Turning a feature off never changes your tournaments")}</strong>
                <p>
                  {gettext(
                    "It hides buttons. Everything already imported - players, clubs, scores, categories - stays exactly as it is, and scores exactly as it did."
                  )}
                </p>
              </div>

              <form id="features-form" phx-change="save_features">
                <%!-- Optional features no federation owns. --%>
                <div :if={Features.general() != []} class="acct-fed" id="features-general">
                  <div class="fed-head">
                    <div class="fed-title">
                      <h3>{gettext("Pairing options")}</h3>
                      <p class="hint">
                        {gettext(
                          "Organisers' rules that are not FIDE's, for any federation. Off until you switch them on."
                        )}
                      </p>
                    </div>
                  </div>

                  <div class="fed-switches">
                    <.setting_toggle
                      :for={feature <- Features.general()}
                      name={"feature[#{feature.key}]"}
                      label={feature.label}
                      hint={feature.description}
                      checked={feature.key in @enabled_features}
                    />
                  </div>
                </div>

                <div :for={federation <- Features.federations()} class="acct-fed">
                  <div class="fed-head">
                    <span class="fed-code">{federation.code}</span>
                    <div class="fed-title">
                      <h3>{federation.name}</h3>
                      <p class="hint">{federation.summary}</p>
                    </div>
                    <span class="fed-count">{on_count(federation.code, @enabled_features)}</span>
                  </div>

                  <div class="fed-switches">
                    <.setting_toggle
                      :for={feature <- Features.catalogue_for(federation.code)}
                      name={"feature[#{feature.key}]"}
                      label={feature.label}
                      hint={feature.description}
                      checked={feature.key in @enabled_features}
                    />
                  </div>

                  <p :if={federation.code == "BEL"} class="hint fed-foot">
                    {gettext(
                      "The player lookup and the bulk club update read the member list the rating list sync downloads. They work with the sync switched off - they just search whatever was last downloaded, which may be an old list, or nothing at all if this machine has never synced."
                    )}
                  </p>
                </div>
              </form>

              <p class="hint acct-foot">
                {gettext(
                  "No other federations are packaged yet. Everything else in the application - FIDE ratings, TRF files, the FIDE report forms - is available to everyone and needs no switch."
                )}
              </p>
            </section>

            <%!-- ============ Your data ============ --%>
            <section id="your-data" class="set-card acct-section" aria-labelledby="your-data-title">
              <div class="acct-section-head">
                <div>
                  <h2 id="your-data-title">{gettext("Your data")}</h2>
                  <p class="hint">
                    {gettext(
                      "One zip with your account settings and a backup of every tournament you can open. Each backup is the same file a tournament's Settings - Export gives you, and goes back in with \"Import backup (JSON)\" on the Tournaments page."
                    )}
                  </p>
                </div>
              </div>

              <dl class="acct-counts" id="data-counts">
                <div>
                  <dt>{gettext("Tournaments")}</dt>
                  <dd>{@data_counts.active}</dd>
                </div>
                <div>
                  <dt>{gettext("Archived")}</dt>
                  <dd>{@data_counts.archived}</dd>
                </div>
                <div>
                  <dt>{gettext("In the recycle bin")}</dt>
                  <dd>{@data_counts.binned}</dd>
                </div>
              </dl>

              <p :if={@data_published?} class="setting-warning" id="data-key-warning">
                {gettext(
                  "Some of these are published on the results site, and their backups carry the publishing key: anyone holding the zip can update or delete those pages. Keep it somewhere private."
                )}
              </p>

              <.sudo_panel
                :if={!@local? and !@sudo?}
                id="data-locked"
                text={gettext("Downloading everything asks you to confirm it's you first.")}
              />

              <div :if={@local? or @sudo?} class="acct-actions">
                <a href={~p"/users/settings/export"} class="pe-btn primary" id="download-data">
                  <.icon name="hero-arrow-down-tray-micro" class="size-4" /> {gettext(
                    "Download everything (.zip)"
                  )}
                </a>
              </div>
            </section>

            <%!-- ============ Delete account ============ --%>
            <section
              :if={!@local?}
              id="delete-account"
              class="set-card acct-section acct-danger"
              aria-labelledby="delete-title"
            >
              <div class="acct-section-head">
                <div>
                  <h2 id="delete-title">{gettext("Delete account")}</h2>
                  <p class="hint">
                    {gettext(
                      "Deletes this account for good. There is no undo, so download your data first."
                    )}
                  </p>
                </div>
              </div>

              <%= if @blockers != [] do %>
                <div class="acct-blocked" id="delete-blocked">
                  <p>
                    <strong>{gettext("This account can't be deleted yet.")}</strong>
                    {gettext(
                      "Deleting it would delete everything it owns with it, so it has to own nothing first:"
                    )}
                  </p>
                  <ul>
                    <li :for={{reason, count} <- @blockers}>{blocker_text(reason, count)}</li>
                  </ul>
                  <p class="hint">
                    {gettext(
                      "Delete the tournaments you no longer need and empty the recycle bin on the Tournaments page, or ask a collaborator to keep a copy from a backup first."
                    )}
                  </p>
                  <.link navigate={~p"/"} class="pe-btn">{gettext("Go to Tournaments")}</.link>
                </div>
              <% else %>
                <ul class="acct-consequences">
                  <li>
                    {gettext("You are signed out everywhere, and this address can register again.")}
                  </li>
                  <li>
                    {gettext(
                      "Tournaments shared with you stay with their owners; you are removed from them, and each one's audit log says you left."
                    )}
                  </li>
                  <li>
                    {gettext(
                      "What you changed in other people's tournaments stays in their audit logs under your address - it is their record of who did what."
                    )}
                  </li>
                  <li>{gettext("Your badge events are deleted with the account.")}</li>
                </ul>

                <.sudo_panel
                  :if={!@sudo?}
                  id="delete-locked"
                  text={gettext("Deleting the account asks you to confirm it's you first.")}
                />

                <.form
                  :if={@sudo?}
                  for={@delete_form}
                  id="delete-account-form"
                  action={~p"/users/settings/delete"}
                  method="post"
                  phx-change="delete_input"
                  phx-submit="delete_account"
                  phx-trigger-action={@delete_trigger}
                >
                  <.input
                    field={@delete_form[:confirm]}
                    type="text"
                    label={gettext("Type %{email} to confirm", email: @user.email)}
                    autocomplete="off"
                    spellcheck="false"
                  />
                  <div class="acct-actions">
                    <button
                      type="submit"
                      class="pe-btn danger"
                      id="delete-account-button"
                      disabled={not Accounts.account_deletion_confirmed?(@user, @delete_confirm)}
                    >
                      {gettext("Delete my account")}
                    </button>
                  </div>
                </.form>
              <% end %>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## ---------- components ----------

  attr :id, :string, required: true
  attr :text, :string, required: true

  # "Confirm it's you" - in place of the controls it guards. Links to the
  # log-in page, which shows its re-authentication form to a signed-in
  # visitor (password, email link, or 02cloud) and comes back here after.
  defp sudo_panel(assigns) do
    ~H"""
    <div class="acct-lock" id={@id}>
      <.icon name="hero-lock-closed" class="size-5 acct-lock-icon" />
      <p>{@text}</p>
      <.link href={~p"/users/log-in"} class="pe-btn tonal">{gettext("Confirm it's you")}</.link>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, default: nil

  # The inline "it worked": beside the button that did it, not in a toast
  # at the far corner of the screen, and announced to a screen reader.
  defp saved(assigns) do
    ~H"""
    <span class="acct-saved" id={@id} role="status">
      <.icon name="hero-check-micro" class="size-4" /> {@text || gettext("Saved")}
    </span>
    """
  end

  ## ---------- labels ----------

  defp initials(%User{} = user) do
    source = user.display_name || user.email |> String.split("@") |> hd()

    source
    |> String.split(~r/[\s._-]+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  defp role_label(user) do
    case User.role(user) do
      :admin -> gettext("Administrator")
      :support -> gettext("Support")
      _ -> ""
    end
  end

  defp locale_options do
    [
      {gettext("Automatic (the browser's language)"), ""}
      | Enum.map(Locale.locales(), fn {code, name} -> {name, code} end)
    ]
  end

  defp theme_options do
    [
      {"", gettext("This device decides")}
      | Enum.map(Preferences.themes(), &{&1, theme_label(&1)})
    ]
  end

  defp accent_options do
    [
      {"", gettext("This device decides")}
      | Enum.map(Preferences.accents(), &{&1, accent_label(&1)})
    ]
  end

  defp accent_swatches, do: @accent_swatches

  # The same msgids as the top-bar pickers in `Layouts`, so the two say the
  # same word for the same theme in every language.
  defp theme_label("system"), do: gettext("System")
  defp theme_label("light"), do: gettext("Light")
  defp theme_label("dark"), do: gettext("Dark")
  defp theme_label("slate"), do: gettext("Slate")
  defp theme_label("mocha"), do: gettext("Mocha")
  defp theme_label("paper"), do: gettext("Paper")
  defp theme_label("board"), do: gettext("Board")
  defp theme_label("contrast"), do: gettext("High Contrast")

  defp accent_label("green"), do: gettext("Green")
  defp accent_label("blue"), do: gettext("Blue")
  defp accent_label("teal"), do: gettext("Teal")
  defp accent_label("violet"), do: gettext("Violet")
  defp accent_label("rose"), do: gettext("Rose")
  defp accent_label("slate"), do: gettext("Slate")
  defp accent_label("indigo"), do: gettext("Indigo")
  defp accent_label("cyan"), do: gettext("Cyan")
  defp accent_label("fuchsia"), do: gettext("Fuchsia")

  defp pairing_system_options do
    Enum.map(Tournament.pairing_systems(), &{Tournament.pairing_system_label(&1), &1})
  end

  defp standard_options do
    Enum.map(RateOfPlay.standard_options(), fn {value, label} -> {label, value} end)
  end

  defp rate_of_play_options(standard, current) do
    standard = if standard in [nil, ""], do: "standard", else: to_string(standard)

    Enum.map(RateOfPlay.select_options(standard, current), fn
      "" -> {gettext("No default"), ""}
      option -> {option, option}
    end)
  end

  defp publish_mode_options do
    Enum.map(Tournament.publish_modes(), &{auto_publish_label(&1), &1})
  end

  defp device_label(ua) do
    case UserAgent.parse(ua) do
      {nil, nil} -> gettext("Unknown browser")
      {browser, nil} -> browser
      {nil, system} -> system
      {browser, system} -> gettext("%{browser} on %{system}", browser: browser, system: system)
    end
  end

  defp device_icon(ua) do
    if UserAgent.mobile?(ua), do: "hero-device-phone-mobile", else: "hero-computer-desktop"
  end

  defp signed_in_label(%DateTime{} = at) do
    case Date.diff(Date.utc_today(), DateTime.to_date(at)) do
      days when days <= 0 -> gettext("Signed in today")
      1 -> gettext("Signed in yesterday")
      days -> ngettext("Signed in %{count} day ago", "Signed in %{count} days ago", days)
    end
  end

  defp blocker_text(:owns_tournaments, count),
    do:
      ngettext(
        "It owns %{count} tournament (archived ones included).",
        "It owns %{count} tournaments (archived ones included).",
        count
      )

  defp blocker_text(:recycle_bin, count),
    do:
      ngettext(
        "%{count} of its tournaments is in the recycle bin, where it can still be restored.",
        "%{count} of its tournaments are in the recycle bin, where they can still be restored.",
        count
      )

  defp blocker_text(:last_admin, _count),
    do:
      gettext(
        "It is the only administrator. Make somebody else an administrator on the Admin page first."
      )

  # How much of a pack is switched on, so the card answers "what is my state
  # here" before anyone reads five labels. Reads fine at zero ("0 of 5 on").
  defp on_count(code, enabled) do
    keys = Enum.map(Features.catalogue_for(code), & &1.key)

    gettext("%{on} of %{total} on",
      on: Enum.count(keys, &(&1 in enabled)),
      total: length(keys)
    )
  end
end
