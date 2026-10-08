defmodule PairingsEngine.Accounts.AccountSettingsTest do
  @moduledoc """
  The account page's context functions - profile, preferences, "New
  tournament" defaults, sessions and deleting an account. See
  docs/account.md.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Accounts, Audit, Repo, Tournaments}
  alias PairingsEngine.Accounts.{Scope, TournamentDefaults, User, UserToken}
  alias PairingsEngine.Audit.AuditLog

  describe "display name" do
    test "is trimmed, inner whitespace collapsed, and blank clears it" do
      user = user_fixture()

      {:ok, user} = Accounts.update_user_profile(user, %{"display_name" => "  Jan \t Peeters "})
      assert user.display_name == "Jan Peeters"

      {:ok, user} = Accounts.update_user_profile(user, %{"display_name" => ""})
      assert user.display_name == nil
    end

    test "has a length cap and refuses control characters" do
      user = user_fixture()

      assert {:error, cs} =
               Accounts.update_user_profile(user, %{"display_name" => String.duplicate("a", 81)})

      assert %{display_name: [_]} = errors_on(cs)

      assert {:error, cs} = Accounts.update_user_profile(user, %{"display_name" => "Jan\u0000x"})
      assert %{display_name: ["must not contain control characters"]} = errors_on(cs)

      # A line break is whitespace, and collapses to a space rather than
      # reaching the invitation email as a new line.
      {:ok, user} = Accounts.update_user_profile(user, %{"display_name" => "Jan\r\nBcc: x"})
      assert user.display_name == "Jan Bcc: x"
    end

    test "labels prefer the name and keep the address within reach" do
      user = user_fixture()
      assert User.display_label(user) == user.email
      assert User.display_with_email(user) == user.email

      named = %{user | display_name: "Jan"}
      assert User.display_label(named) == "Jan"
      assert User.display_with_email(named) == "Jan (#{user.email})"
    end
  end

  describe "preferences" do
    test "only values the app knows are stored" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_user_preferences(user, %{
          "locale" => "nl",
          "theme" => "tomw",
          "accent" => "teal"
        })

      assert {user.locale, user.theme, user.accent} == {"nl", "tomw", "teal"}

      assert {:error, cs} = Accounts.update_user_preferences(user, %{"theme" => "nord"})
      assert %{theme: [_]} = errors_on(cs)
      assert {:error, _} = Accounts.update_user_preferences(user, %{"locale" => "xx"})
      assert {:error, _} = Accounts.update_user_preferences(user, %{"accent" => "#ff0000"})
    end

    test "a blank clears one without touching the others" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_user_preferences(user, %{"theme" => "dark", "accent" => "rose"})

      {:ok, user} = Accounts.update_user_preferences(user, %{"theme" => ""})

      assert user.theme == nil
      assert user.accent == "rose"
    end

    test "put_user_preference/3 does not write when nothing changes" do
      user = user_fixture()
      {:ok, user} = Accounts.put_user_preference(user, :locale, "nl")
      stamp = user.updated_at

      assert {:ok, ^user} = Accounts.put_user_preference(user, :locale, "nl")
      assert Repo.get!(User, user.id).updated_at == stamp
    end
  end

  describe "tournament defaults" do
    test "store, normalise and validate" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_tournament_defaults(user, %{
          "pairing_system" => "keizer",
          "rounds_count" => "12",
          "standard" => "rapid",
          "federation" => " ned ",
          "organizer" => " KSK ",
          "publish_mode" => "pairings",
          "publish_delay_minutes" => "15"
        })

      d = user.tournament_defaults
      assert %TournamentDefaults{pairing_system: "keizer", rounds_count: 12} = d
      assert d.federation == "NED"
      assert d.organizer == "KSK"

      for {field, value} <- [
            {"pairing_system", "dutch"},
            {"rounds_count", "0"},
            {"standard", "bullet"},
            {"federation", "NE"},
            {"publish_mode", "whenever"},
            # Retired on 2026-09-28 - the migration converts stored ones.
            {"publish_mode", "timed"},
            {"publish_delay_minutes", "-1"}
          ] do
        assert {:error, _} = Accounts.update_tournament_defaults(user, %{field => value}),
               "#{field} = #{inspect(value)} should be refused"
      end
    end

    test "split between what the form shows and what the create path adds" do
      defaults = %TournamentDefaults{
        pairing_system: "round_robin",
        rounds_count: 7,
        city: "Gent",
        federation: "BEL",
        publish_mode: "manual",
        publish_delay_minutes: 30
      }

      assert TournamentDefaults.form_params(defaults) == %{
               "pairing_system" => "round_robin",
               "rounds_count" => "7",
               "city" => "Gent"
             }

      # The delay means nothing without the pairings step, so it does not travel.
      assert TournamentDefaults.hidden_params(defaults) == %{
               "federation" => "BEL",
               "publish_mode" => "manual"
             }

      for mode <- ~w(pairings results standings) do
        assert TournamentDefaults.hidden_params(%{defaults | publish_mode: mode})[
                 "publish_delay_minutes"
               ] == "30"
      end

      # A value stored before 2026-09-28 is converted, not handed to a
      # changeset that would refuse the whole new tournament.
      assert %{"publish_mode" => "pairings", "publish_delay_minutes" => "30"} =
               TournamentDefaults.hidden_params(%{defaults | publish_mode: "timed"})

      assert TournamentDefaults.hidden_params(%{defaults | publish_mode: "immediate"})[
               "publish_mode"
             ] == "standings"

      assert TournamentDefaults.form_params(nil) == %{}
      refute TournamentDefaults.any?(nil)
      refute TournamentDefaults.any?(%TournamentDefaults{})
    end
  end

  describe "sessions" do
    test "record the browser, cut to the column" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user, String.duplicate("x", 400))

      row = Repo.get_by!(UserToken, token: token)
      assert String.length(row.user_agent) == 255
    end

    test "are listed newest first, sessions only" do
      user = user_fixture()
      a = Accounts.generate_user_session_token(user, "A")
      _link = Accounts.deliver_login_instructions(user, &"/#{&1}")

      assert [%UserToken{token: ^a} | _] = Accounts.list_user_sessions(user)
      assert Enum.all?(Accounts.list_user_sessions(user), &(&1.context == "session"))
    end

    test "delete_user_session/2 is scoped to the account" do
      user = user_fixture()
      other = user_fixture()
      theirs = Accounts.generate_user_session_token(other)
      row = Repo.get_by!(UserToken, token: theirs)

      assert {:error, :not_found} = Accounts.delete_user_session(user, row.id)
      assert {:error, :not_found} = Accounts.delete_user_session(user, "not-a-number")
      assert Accounts.get_user_by_session_token(theirs)

      assert {:ok, _} = Accounts.delete_user_session(other, to_string(row.id))
      refute Accounts.get_user_by_session_token(theirs)
    end

    test "delete_other_user_sessions/2 keeps the current one and pending links" do
      user = user_fixture()
      current = Accounts.generate_user_session_token(user)
      other = Accounts.generate_user_session_token(user)

      {:ok, _} =
        Accounts.deliver_user_update_email_instructions(
          %{user | email: unique_user_email()},
          user.email,
          &"/#{&1}"
        )

      {:ok, ended} = Accounts.delete_other_user_sessions(user, current)

      assert Enum.map(ended, & &1.token) == [other]
      assert Accounts.get_user_by_session_token(current)
      refute Accounts.get_user_by_session_token(other)

      assert Repo.exists?(
               from t in UserToken, where: t.user_id == ^user.id and t.context != "session"
             )
    end
  end

  describe "deleting an account" do
    test "is refused while it owns a tournament, archived or binned" do
      user = user_fixture()
      scope = Scope.for_user(user)
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Mine", "rounds_count" => 3})

      assert [{:owns_tournaments, 1}] = Accounts.account_deletion_blockers(user)
      assert {:error, {:blocked, _}} = Accounts.delete_user_account(user)
      assert Repo.get(User, user.id)

      {:ok, _} = Tournaments.soft_delete_tournament(t)
      assert [{:recycle_bin, 1}] = Accounts.account_deletion_blockers(user)
      assert {:error, {:blocked, _}} = Accounts.delete_user_account(user)
      assert Repo.get(Tournaments.Tournament, t.id)
    end

    test "is refused for the only administrator" do
      user = user_fixture()
      {:ok, admin} = Accounts.set_role(user.email, :admin)

      assert [{:last_admin, 1}] = Accounts.account_deletion_blockers(admin)

      {:ok, _second} = Accounts.set_role(user_fixture().email, :admin)
      assert [] = Accounts.account_deletion_blockers(admin)
    end

    test "leaves shared tournaments with their owners and keeps who did what" do
      owner = user_fixture()
      leaver = user_fixture()
      owner_scope = Scope.for_user(owner)
      leaver_scope = Scope.for_user(leaver)

      {:ok, t} =
        Tournaments.create_tournament(owner_scope, %{"name" => "Club", "rounds_count" => 3})

      {:ok, c} = Tournaments.add_collaborator(owner_scope, t, leaver.email)
      {:ok, _} = Tournaments.accept_invitation(leaver_scope, c.invite_token)
      {:ok, _} = Audit.log(t.id, leaver_scope, "tournament.renamed", %{from: "a", to: "b"})
      session = Accounts.generate_user_session_token(leaver)

      assert {:ok, %{tokens: tokens, tournament_ids: [tid]}} =
               Accounts.delete_user_account(leaver)

      assert tid == t.id
      assert Enum.any?(tokens, &(&1.token == session))

      refute Repo.get(User, leaver.id)
      assert Repo.get(Tournaments.Tournament, t.id)
      assert Tournaments.list_collaborators(t) == []

      rows = Repo.all(from a in AuditLog, where: a.tournament_id == ^t.id)
      renamed = Enum.find(rows, &(&1.action == "tournament.renamed"))
      assert renamed.user_id == nil
      assert renamed.details["former_actor"] == leaver.email

      left = Enum.find(rows, &(&1.action == "tournament.left"))
      assert left.details["former_actor"] == leaver.email
      assert left.details["reason"] == "account_deleted"

      assert PairingsEngineWeb.AuditLive.actor(Repo.preload(renamed, :user)) =~ leaver.email
      assert PairingsEngineWeb.AuditLive.actor(Repo.preload(renamed, :user)) =~ "account deleted"
    end

    test "the typed confirmation is the account's own address" do
      user = user_fixture()
      assert Accounts.account_deletion_confirmed?(user, "  " <> String.upcase(user.email) <> " ")
      refute Accounts.account_deletion_confirmed?(user, "DELETE")
      refute Accounts.account_deletion_confirmed?(user, nil)
    end
  end
end
