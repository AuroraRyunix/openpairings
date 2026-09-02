defmodule PairingsEngine.MobileFrozenTest do
  @moduledoc """
  Enrolling a phone for a tournament that has gone read-only.

  A mobile enrollment is a bearer credential minted for one tournament, and
  minting one has always been ungated. The failure that follows is quiet and
  badly timed: the QR scans, the phone loads the round, the helper taps a
  result - and only then does the write meet `ensure_writable/1` and bounce.
  The arbiter finds out at the board, mid-round, from somebody else's phone,
  which is the worst possible place to discover that this copy of the
  tournament is not the live one.

  Refusing at the QR is the same information delivered where it can still be
  acted on: take the tournament back, then enrol the phone.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Mobile, Repo, Tournaments}
  alias PairingsEngine.Mobile.Enrollment
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "mobile#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament do
    {:ok, t} =
      Tournaments.create_tournament(user_scope(), %{
        "name" => "Mobile Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    t
  end

  defp freeze(t, :archived) do
    {:ok, frozen} = Tournaments.archive_tournament(t)
    frozen
  end

  defp freeze(t, :handed_off) do
    {:ok, frozen} = Tournaments.hand_off(t, "the club PC")
    frozen
  end

  for reason <- [:archived, :handed_off] do
    describe "a #{reason} tournament" do
      test "mints no enrollment" do
        t = freeze(tournament(), unquote(reason))

        assert Mobile.create_enrollment(t.id) == {:error, unquote(reason)}
        assert Mobile.list_enrollments(t.id) == []
        assert Repo.all(Enrollment) == []
      end

      test "refuses even when a label and a lifetime are asked for" do
        t = freeze(tournament(), unquote(reason))

        assert Mobile.create_enrollment(t.id, label: "Board 1", ttl_hours: 2) ==
                 {:error, unquote(reason)}
      end

      test "cannot have a phone revoked here either" do
        # The revocation list of a tournament that is not live here is not
        # this copy's to edit: it belongs with the copy actually running the
        # event. The credential is inert against a frozen tournament anyway -
        # every result write goes through the same gate.
        t = tournament()
        {:ok, enrollment} = Mobile.create_enrollment(t.id)
        frozen = freeze(t, unquote(reason))

        assert Mobile.revoke(enrollment) == {:error, unquote(reason)}
        assert Mobile.revoke(frozen.id, enrollment.id) == {:error, unquote(reason)}
        refute Repo.reload!(enrollment).revoked_at
      end
    end
  end

  describe "once it is writable again" do
    test "enrolling and revoking work exactly as before" do
      t = tournament()
      {:ok, handed} = Tournaments.hand_off(t, "the club PC")

      assert Mobile.create_enrollment(handed.id) == {:error, :handed_off}

      {:ok, back} = Tournaments.take_back(handed, handed.handoff_token)

      assert {:ok, enrollment} = Mobile.create_enrollment(back.id)
      assert {:ok, revoked} = Mobile.revoke(enrollment)
      assert revoked.revoked_at
    end
  end

  describe "an enrollment for a tournament that is not there" do
    test "still fails on the missing row rather than on the gate" do
      # `ensure_writable/1` answers `:ok` for an id with no tournament -
      # there is nothing to protect - so the foreign key stays the thing that
      # refuses, exactly as loudly as it did before the gate was added. The
      # new refusal must not quietly become the answer to a different
      # question.
      assert_raise Ecto.ConstraintError, fn -> Mobile.create_enrollment(999_999) end
    end

    test "revoking one that does not exist is still :not_found" do
      t = tournament()
      assert Mobile.revoke(t.id, 999_999) == {:error, :not_found}
    end
  end
end
