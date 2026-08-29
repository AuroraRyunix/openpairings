defmodule PairingsEngineWeb.AdminLive do
  @moduledoc """
  Who may administer this installation, and what it is.

  ## Roles are editable here, and that is a change of mind worth recording

  `mix pairings.role` was built with a moduledoc saying there should be no
  screen for this, on the argument that shell access is the one credential
  that cannot be circular. **That argument was about the FIRST administrator
  and it still holds** - a hosted box has nobody until `ADMIN_EMAILS` or the
  mix task says so, and nothing here can bootstrap that.

  It does not extend to the second. Once an administrator exists, letting
  them grant `support` to a colleague adds no authority they did not already
  have: the same session can repoint where the installation publishes and
  download the entire database. Requiring SSH for the smaller act while the
  larger one is two clicks away is a rule that only inconveniences the
  honest.

  ## Three guards, each for a way this locks somebody out

    * **You cannot change your own role.** One misclick would otherwise cost
      an administrator their own access, on the one page that could restore
      it.
    * **The last administrator cannot be demoted.** An installation with no
      administrator is recoverable only over SSH, which is exactly the
      situation the deploy configuration exists to prevent.
    * **Declared administrators are shown but not editable.** `ADMIN_EMAILS`
      lives in the systemd unit; a button here that appeared to revoke one
      and was undone by the next restart would be a lie.

  ## What is deliberately not here

  No user deletion, no password reset, no impersonation. Each is a genuine
  support need and each is a much bigger decision than "who may change the
  publishing address", which is all this page was asked for.

  ## Recent activity

  A role change here, a backup download, and the publishing/sync actions on
  the Connections page are the acts with the widest reach in the app - each
  is machine-wide rather than about one tournament - so this page also shows
  the most recent of them, via `PairingsEngine.Audit.list_machine_wide/1`.
  It is deliberately a short, unpaginated list: this is "what changed
  recently", not the full tournament-style audit trail those acts are too
  broad to belong to (see `PairingsEngineWeb.AuditLive`).
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Accounts
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Audit
  alias PairingsEngine.Authz
  alias PairingsEngineWeb.AuditLive

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Admin") |> load()}
  end

  @recent_activity_limit 20

  defp load(socket) do
    assign(socket,
      users: Accounts.list_users(),
      declared: Authz.declared_admin_emails(),
      pending: nil,
      recent_activity: Audit.list_machine_wide(limit: @recent_activity_limit)
    )
  end

  @impl true
  def handle_event("ask", %{"id" => id, "role" => role}, socket) do
    user = Enum.find(socket.assigns.users, &(to_string(&1.id) == id))

    cond do
      is_nil(user) ->
        {:noreply, socket}

      # Guarded here as well as in the markup, because a hidden control still
      # accepts a crafted event.
      not editable?(socket.assigns, user) ->
        {:noreply, put_flash(socket, :error, refusal(socket.assigns, user))}

      true ->
        {:noreply, assign(socket, pending: %{user: user, role: role})}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, pending: nil)}

  def handle_event("confirm", _params, %{assigns: %{pending: %{user: user, role: role}}} = socket) do
    if editable?(socket.assigns, user) and not last_admin_demotion?(socket.assigns, user, role) do
      from_role = User.role(user) |> to_string()
      {:ok, updated} = Accounts.set_role(user.email, role)

      Logger.info(
        "Role changed: #{updated.email} is now #{role} " <>
          "(by #{socket.assigns.current_scope.user.email})"
      )

      Audit.log_system(socket.assigns.current_scope, "admin.role_changed", %{
        email: updated.email,
        changed_fields: %{role: [from_role, role]}
      })

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, gettext("%{email} is now %{role}", email: updated.email, role: role))}
    else
      {:noreply,
       socket |> assign(pending: nil) |> put_flash(:error, refusal(socket.assigns, user))}
    end
  end

  def handle_event("confirm", _params, socket), do: {:noreply, socket}

  defp editable?(assigns, user) do
    user.id != assigns.current_scope.user.id and not declared?(assigns, user)
  end

  defp declared?(assigns, user), do: String.downcase(user.email) in assigns.declared

  # "Last" counts the database only. A declared administrator would survive a
  # demotion here, but relying on that would make the guard depend on a file
  # this page cannot see the current contents of.
  defp last_admin_demotion?(assigns, user, new_role) do
    User.role(user) == :admin and new_role != "admin" and
      Enum.count(assigns.users, &(User.role(&1) == :admin)) <= 1
  end

  defp refusal(assigns, user) do
    cond do
      user.id == assigns.current_scope.user.id ->
        gettext("You cannot change your own role.")

      declared?(assigns, user) ->
        gettext(
          "This address is set in the server's configuration, so it cannot be changed here."
        )

      true ->
        gettext("This is the last administrator, so the role cannot be taken away.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active="admin"
    >
      <h1>{gettext("Admin")}</h1>

      <div class="set-card">
        <h2>{gettext("Who may administer this installation")}</h2>
        <p class="hint">
          {gettext(
            "An administrator can change where this machine publishes, download a backup, and update the rating lists. Support can see those things without changing them."
          )}
        </p>

        <table class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Account")}</th>
              <th>{gettext("Role")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={user <- @users}>
              <td>
                {user.email}
                <span :if={user.id == @current_scope.user.id} class="hint">
                  {gettext("(you)")}
                </span>
                <span :if={declared?(assigns, user)} class="hint">
                  {gettext("(set in the server configuration)")}
                </span>
              </td>
              <td>{role_label(user)}</td>
              <td class="num">
                <div :if={editable?(assigns, user)} class="actions">
                  <button
                    :for={role <- User.roles()}
                    :if={to_string(User.role(user)) != role}
                    type="button"
                    class="pe-btn"
                    phx-click="ask"
                    phx-value-id={user.id}
                    phx-value-role={role}
                  >
                    {role_label(role)}
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>

        <p :if={@declared != []} class="hint" style="margin-top: 12px">
          {gettext(
            "Addresses set in the server's configuration always administer, whether or not they have an account here yet. Remove them from ADMIN_EMAILS to revoke."
          )}
        </p>
      </div>

      <div :if={@pending} class="set-card" style="border-color: var(--warn)">
        <h2>{gettext("Change this role?")}</h2>
        <p>
          {gettext("%{email} becomes %{role}.",
            email: @pending.user.email,
            role: role_label(@pending.role)
          )}
        </p>
        <div class="actions">
          <button type="button" class="pe-btn primary" phx-click="confirm">
            {gettext("Change the role")}
          </button>
          <button type="button" class="pe-btn" phx-click="cancel">{gettext("Cancel")}</button>
        </div>
      </div>

      <div class="set-card">
        <h2>{gettext("This installation")}</h2>
        <dl class="pe-facts">
          <dt>{gettext("Version")}</dt>
          <dd>v{Application.spec(:pairings_engine, :vsn)}</dd>
          <dt>{gettext("Running as")}</dt>
          <dd>
            {if Authz.local_mode?(),
              do: gettext("a local install (no accounts, no roles needed)"),
              else: gettext("a hosted server")}
          </dd>
          <dt>{gettext("Database")}</dt>
          <dd>{database_size()}</dd>
        </dl>
        <p class="hint">
          {gettext("Backups, publishing and the rating lists are on the Connections page.")}
        </p>
      </div>

      <div class="set-card">
        <h2>{gettext("Recent activity")}</h2>
        <p class="hint">
          {gettext(
            "The most recent machine-wide actions: role changes, backup downloads, publishing changes and rating-list syncs."
          )}
        </p>

        <div class="card table-card">
          <table class="pe-table">
            <thead>
              <tr>
                <th style="width: 150px">{gettext("When")}</th>
                <th style="width: 220px">{gettext("Who")}</th>
                <th>{gettext("What")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@recent_activity == []}>
                <td colspan="3">
                  <div class="empty">
                    <p class="hint">{gettext("No installation-wide activity recorded yet.")}</p>
                  </div>
                </td>
              </tr>

              <tr :for={entry <- @recent_activity}>
                <td style="white-space: nowrap">{AuditLive.format_time(entry.inserted_at)}</td>
                <td>{AuditLive.actor(entry)}</td>
                <td>{AuditLive.describe(entry)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp role_label(%User{} = user), do: user |> User.role() |> to_string() |> role_label()
  defp role_label("admin"), do: gettext("Administrator")
  defp role_label("support"), do: gettext("Support")
  defp role_label("owner"), do: gettext("Account owner")
  defp role_label(other), do: other

  defp database_size do
    path = Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]

    case File.stat(path) do
      {:ok, %{size: bytes}} -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      _ -> gettext("unknown")
    end
  end
end
