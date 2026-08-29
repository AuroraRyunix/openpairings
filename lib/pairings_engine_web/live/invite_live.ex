defmodule PairingsEngineWeb.InviteLive do
  @moduledoc """
  `/invites/:token` - accept or decline a tournament collaborator
  invitation (see `docs/teams.md`). Reached from the link in the
  invitation email (`PairingsEngine.Accounts.UserNotifier.deliver_invitation/4`,
  sent by `PairingsEngine.Tournaments.add_collaborator/3`) or shared
  manually by the owner if that email failed to send.

  Requires login (this route sits in the `:require_authenticated_tournaments`
  live_session) - an invitee with no account yet is bounced through the
  normal magic-link login/registration flow first, then lands back here.

  Being added never grants access by itself: this page is the only way an
  invitation actually turns into access, via
  `PairingsEngine.Tournaments.accept_invitation/2`, which also requires the
  logged-in user's email to match the invitation's - otherwise this shows a
  "sent to a different address" message and does nothing, so a stray click
  on someone else's forwarded invite link can't be used to claim access.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Accounts, Tournaments}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Invitation", token: token)
     |> load_invitation()}
  end

  defp load_invitation(socket) do
    scope = socket.assigns.current_scope

    # By token only. Resolving a numeric segment as a collaborator id would
    # make every pending invitation in the system readable by walking
    # `/invites/1`, `/invites/2`, ... - see `find_invitation_by_token/1`.
    case Tournaments.find_invitation_by_token(socket.assigns.token) do
      nil ->
        assign(socket, invitation: nil, tournament: nil, owner_email: nil, mismatch?: false)

      %{status: "pending"} = collaborator ->
        tournament = Tournaments.get_tournament!(collaborator.tournament_id)
        owner = Accounts.get_user!(tournament.user_id)
        mismatch? = normalize(collaborator.email) != normalize(scope.user.email)

        assign(socket,
          invitation: collaborator,
          tournament: tournament,
          owner_email: owner.email,
          mismatch?: mismatch?
        )

      %{} ->
        # Already accepted or previously declined-then-reused link.
        assign(socket, invitation: nil, tournament: nil, owner_email: nil, mismatch?: false)
    end
  end

  defp normalize(email), do: email |> to_string() |> String.trim() |> String.downcase()

  # No loaded invitation means the token matched nothing, so there is nothing
  # to act on - and in particular the raw URL segment never reaches
  # `find_invitation/1`'s id branch from here.
  @impl true
  def handle_event(event, _params, %{assigns: %{invitation: nil}} = socket)
      when event in ["accept", "decline"] do
    {:noreply, socket}
  end

  def handle_event("accept", _params, socket) do
    case Tournaments.accept_invitation(socket.assigns.current_scope, socket.assigns.token) do
      {:ok, collaborator} ->
        {:noreply,
         socket
         |> put_flash(:info, "You now have access to #{socket.assigns.tournament.name}.")
         |> push_navigate(to: ~p"/t/#{collaborator.tournament_id}/players")}

      {:error, :email_mismatch} ->
        {:noreply, assign(socket, mismatch?: true)}

      {:error, :not_found} ->
        {:noreply, assign(socket, invitation: nil)}
    end
  end

  def handle_event("decline", _params, socket) do
    case Tournaments.decline_invitation(socket.assigns.current_scope, socket.assigns.token) do
      {:ok, _collaborator} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation declined.")
         |> push_navigate(to: ~p"/")}

      {:error, :email_mismatch} ->
        {:noreply, assign(socket, mismatch?: true)}

      {:error, :not_found} ->
        {:noreply, assign(socket, invitation: nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app publish_status={assigns[:publish_status]} flash={@flash} current_path={assigns[:current_path]} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="card">
          <%= cond do %>
            <% is_nil(@invitation) -> %>
              <h2>{gettext("Invitation not found")}</h2>
              <p class="hint">
                {gettext("This invitation link is invalid, has already been used, or was declined.")}
              </p>
              <div class="actions">
                <.link navigate={~p"/"} class="pe-btn">{gettext("Go to Tournaments")}</.link>
              </div>
            <% @mismatch? -> %>
              <h2>{gettext("Wrong account")}</h2>
              <p class="hint">
                <.rich_text text={
                  gettext(
                    "This invitation was sent to %[invited], but you're signed in as %[current]. Log in with the invited address to accept it."
                  )
                }>
                  <:part name="invited"><strong>{@invitation.email}</strong></:part>
                  <:part name="current"><strong>{@current_scope.user.email}</strong></:part>
                </.rich_text>
              </p>
              <div class="actions">
                <.link navigate={~p"/"} class="pe-btn">{gettext("Go to Tournaments")}</.link>
              </div>
            <% true -> %>
              <h2>{gettext("You've been invited")}</h2>
              <p class="hint" style="margin-top: 0">
                <.rich_text text={
                  gettext(
                    "%[owner] invited you to collaborate on %[tournament]. Accepting gives you full editing access to this tournament - everything the owner can do, except managing collaborators or deleting it."
                  )
                }>
                  <:part name="owner"><strong>{@owner_email}</strong></:part>
                  <:part name="tournament"><strong>{@tournament.name}</strong></:part>
                </.rich_text>
              </p>
              <div class="actions">
                <button type="button" class="pe-btn primary" phx-click="accept">{gettext("Accept")}</button>
                <button type="button" class="pe-btn" phx-click="decline">{gettext("Decline")}</button>
              </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
