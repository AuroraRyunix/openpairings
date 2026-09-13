defmodule PairingsEngine.Accounts.UserNotifier do
  @moduledoc """
  Builds and sends every account-related email: the magic-link / confirmation
  login mail, the email-change confirmation, and (called from
  `PairingsEngine.Tournaments.add_collaborator/3`) a collaborator invitation.

  ## Locale

  Every message here is built and sent SYNCHRONOUSLY, in whatever process
  called in - a LiveView `handle_event`, in every current caller - rather
  than handed to a Task, an Oban job or a GenServer. That matters because
  `Gettext.put_locale/1` is per-process: `PairingsEngineWeb.Plugs.Locale`
  and `PairingsEngineWeb.LocaleHook` (see docs/i18n.md's "two traps") have
  already set it for that process before any of these functions run, so a
  plain `gettext/1` call below picks it up for free. Losing that would mean
  reproducing the exact trap docs/i18n.md documents for a LiveView's dead
  render; the fix is simply to never introduce the process hop.

  For `deliver_invitation/4` specifically, "whoever's locale" is the
  INVITING arbiter's, not the invitee's - the invitee may not have an
  OpenPairings account yet, so there is no other signal to key off, and
  nothing in this app persists a per-user locale (see docs/i18n.md, "Not
  built").
  """

  import Swoosh.Email

  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.Mailer
  alias PairingsEngine.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    # Use the SMTP_USERNAME if available, otherwise use the placeholder address.
    from_address = System.get_env("SMTP_USERNAME") || "contact@example.com"

    email =
      new()
      |> to(recipient)
      |> from({"OpenPairings", from_address})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, gettext("Update email instructions"), """

    ==============================

    #{gettext("Hi %{email},", email: user.email)}

    #{gettext("You can change your email by visiting the URL below:")}

    #{url}

    #{gettext("If you didn't request this change, please ignore this.")}

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, gettext("Log in instructions"), """

    ==============================

    #{gettext("Hi %{email},", email: user.email)}

    #{gettext("You can log into your account by visiting the URL below:")}

    #{url}

    #{gettext("If you didn't request this email, please ignore this.")}

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, gettext("Confirmation instructions"), """

    ==============================

    #{gettext("Hi %{email},", email: user.email)}

    #{gettext("You can confirm your account by visiting the URL below:")}

    #{url}

    #{gettext("If you didn't create an account with us, please ignore this.")}

    ==============================
    """)
  end

  @doc """
  Delivers a tournament collaborator invitation to `email`. Sent from
  `PairingsEngine.Tournaments.add_collaborator/3` when a tournament's owner
  invites someone; `url` points at `/invites/:token` (see
  `PairingsEngineWeb.InviteLive`), which requires login (the invitee's
  magic-link flow creates their account if they don't have one yet) and lets
  them accept or decline.

  Returns `{:ok, email} | {:error, reason}` - see the moduledoc's note on
  `deliver/3` above. The caller, `PairingsEngine.Tournaments`, is what turns
  that into the `collaborator.mail_status` the owner sees; it must not
  assume this always succeeds.
  """
  def deliver_invitation(email, owner_email, tournament_name, url) do
    deliver(
      email,
      gettext("You've been invited to %{tournament}", tournament: tournament_name),
      """

      ==============================

      #{gettext("Hi,")}

      #{gettext(~s(%{owner} invited you to work on the tournament "%{tournament}" on OpenPairings.),
      owner: owner_email,
      tournament: tournament_name)}

      #{gettext("Open the link below to accept (or decline) the invitation:")}

      #{url}

      #{gettext("If you weren't expecting this, you can safely ignore this email.")}

      ==============================
      """
    )
  end
end
