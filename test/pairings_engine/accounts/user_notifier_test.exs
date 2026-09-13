defmodule PairingsEngine.Accounts.UserNotifierTest do
  @moduledoc """
  Content and locale coverage for every email `UserNotifier` builds.

  Before this file, none of the four templates (magic-link, confirmation,
  update-email, collaborator invitation) had a test that looked at the
  rendered subject or body at all - `accounts_test.exs` only checked that a
  token was created, and `tournaments_test.exs` only checked that AN email
  was sent, not what language it was in. Every string here was hardcoded
  English with no `gettext/1` call anywhere, so nothing could have caught a
  regression back to that.

  Plain structs throughout - no DB needed, since `UserNotifier` only reads
  `user.email` and `user.confirmed_at`.
  """
  use ExUnit.Case, async: true
  import Swoosh.TestAssertions

  alias PairingsEngine.Accounts.{User, UserNotifier}

  @confirmed %User{email: "arbiter@example.com", confirmed_at: ~U[2026-01-01 00:00:00Z]}
  @unconfirmed %User{email: "new-user@example.com", confirmed_at: nil}
  @url "https://openpairings.example.org/users/log-in/sometoken"

  setup do
    # Each ExUnit test runs in its own process and Gettext.put_locale/2 is
    # per-process, so this never leaks between tests - set explicitly rather
    # than assumed, since "en" is also just whatever the last call left
    # behind in THIS process.
    Gettext.put_locale(PairingsEngineWeb.Gettext, "en")
    :ok
  end

  describe "deliver_login_instructions/2 - confirmed user (magic link)" do
    test "English by default" do
      assert {:ok, _email} = UserNotifier.deliver_login_instructions(@confirmed, @url)

      assert_email_sent(fn email ->
        email.subject == "Log in instructions" and
          email.text_body =~ "Hi #{@confirmed.email}," and
          email.text_body =~ "You can log into your account by visiting the URL below:" and
          email.text_body =~ @url and
          email.html_body == nil
      end)
    end

    test "renders in Dutch when the calling process' locale is Dutch" do
      Gettext.put_locale(PairingsEngineWeb.Gettext, "nl")

      assert {:ok, _email} = UserNotifier.deliver_login_instructions(@confirmed, @url)

      assert_email_sent(fn email ->
        email.subject == "Instructies om in te loggen" and
          email.text_body =~ "Hallo #{@confirmed.email}," and
          email.text_body =~ "Je kunt inloggen op je account via onderstaande link:" and
          email.text_body =~ @url
      end)
    end
  end

  describe "deliver_login_instructions/2 - unconfirmed user (confirmation)" do
    test "English by default" do
      assert {:ok, _email} = UserNotifier.deliver_login_instructions(@unconfirmed, @url)

      assert_email_sent(fn email ->
        email.subject == "Confirmation instructions" and
          email.text_body =~ "You can confirm your account by visiting the URL below:"
      end)
    end

    test "renders in Dutch when the calling process' locale is Dutch" do
      Gettext.put_locale(PairingsEngineWeb.Gettext, "nl")

      assert {:ok, _email} = UserNotifier.deliver_login_instructions(@unconfirmed, @url)

      assert_email_sent(fn email ->
        email.subject == "Instructies ter bevestiging" and
          email.text_body =~ "Je kunt je account bevestigen via onderstaande link:"
      end)
    end
  end

  describe "deliver_update_email_instructions/2" do
    test "English by default" do
      assert {:ok, _email} = UserNotifier.deliver_update_email_instructions(@confirmed, @url)

      assert_email_sent(fn email ->
        email.subject == "Update email instructions" and
          email.text_body =~ "You can change your email by visiting the URL below:" and
          email.text_body =~ "If you didn't request this change, please ignore this."
      end)
    end

    test "renders in Dutch when the calling process' locale is Dutch" do
      Gettext.put_locale(PairingsEngineWeb.Gettext, "nl")

      assert {:ok, _email} = UserNotifier.deliver_update_email_instructions(@confirmed, @url)

      assert_email_sent(fn email ->
        email.subject == "Instructies voor het wijzigen van je e-mailadres" and
          email.text_body =~ "Je kunt je e-mailadres wijzigen via onderstaande link:"
      end)
    end
  end

  describe "deliver_invitation/4" do
    test "English by default, subject and body carry the tournament name and inviter" do
      assert {:ok, _email} =
               UserNotifier.deliver_invitation(
                 "invitee@example.com",
                 "owner@example.com",
                 "Autumn Open",
                 @url
               )

      assert_email_sent(fn email ->
        email.subject == "You've been invited to Autumn Open" and
          email.text_body =~
            ~s(owner@example.com invited you to work on the tournament "Autumn Open" on OpenPairings.) and
          email.text_body =~ @url
      end)
    end

    test "renders in the INVITING ARBITER's locale (the invitee has none on file)" do
      # The invitee may not even have an OpenPairings account yet - see the
      # moduledoc. Using the calling process' locale means this follows
      # whoever is at the keyboard clicking "invite", exactly like the rest
      # of the arbiter UI.
      Gettext.put_locale(PairingsEngineWeb.Gettext, "nl")

      assert {:ok, _email} =
               UserNotifier.deliver_invitation(
                 "invitee@example.com",
                 "owner@example.com",
                 "Herfstopen",
                 @url
               )

      assert_email_sent(fn email ->
        email.subject == "Je bent uitgenodigd voor Herfstopen" and
          email.text_body =~
            ~s(owner@example.com heeft je uitgenodigd om mee te werken aan het toernooi "Herfstopen" op OpenPairings.)
      end)
    end
  end
end
