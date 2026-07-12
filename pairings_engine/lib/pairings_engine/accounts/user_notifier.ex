defmodule PairingsEngine.Accounts.UserNotifier do
  import Swoosh.Email

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
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

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
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

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
  """
  def deliver_invitation(email, owner_email, tournament_name, url) do
    deliver(email, "You've been invited to #{tournament_name}", """

    ==============================

    Hi,

    #{owner_email} invited you to work on the tournament "#{tournament_name}" on OpenPairings.

    Open the link below to accept (or decline) the invitation:

    #{url}

    If you weren't expecting this, you can safely ignore this email.

    ==============================
    """)
  end
end
