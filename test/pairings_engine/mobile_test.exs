defmodule PairingsEngine.MobileTest do
  use PairingsEngine.DataCase, async: true

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Mobile, Tournaments}
  alias PairingsEngine.Mobile.Enrollment

  defp tournament do
    scope = user_scope_fixture()
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Enrol Test", "type" => "swiss"})
    t
  end

  describe "create_enrollment/2" do
    test "produces a URL token and an 8-digit numeric code" do
      {:ok, e} = Mobile.create_enrollment(tournament().id)

      assert byte_size(e.token) >= 20
      assert e.code =~ ~r/^\d{8}$/
      assert DateTime.compare(e.expires_at, DateTime.utc_now()) == :gt
    end

    test "codes spread across the whole 8-digit range" do
      # A cheap smoke test that the generator is not stuck in a corner of the
      # range (a bad rejection-sampling bound, an off-by-a-decade start), and
      # that repeated calls do not collide.
      codes =
        for _ <- 1..40 do
          {:ok, e} = Mobile.create_enrollment(tournament().id)
          String.to_integer(e.code)
        end

      assert Enum.all?(codes, &(&1 >= 10_000_000 and &1 <= 99_999_999))
      assert length(Enum.uniq(codes)) == 40
      assert Enum.max(codes) - Enum.min(codes) > 10_000_000
    end

    test "the database refuses a second un-revoked row with the same code" do
      # Uniqueness used to be a read-then-insert that gave up after twenty
      # attempts and inserted the duplicate anyway. It is a partial unique
      # index now, so nothing - not this module, not a stray script - can
      # produce the pair that made `get_active_by_code/1` raise.
      t = tournament()
      {:ok, first} = Mobile.create_enrollment(t.id)

      assert_raise Ecto.ConstraintError, ~r/unique_constraint/, fn ->
        Repo.insert!(%Enrollment{
          tournament_id: t.id,
          token: "a-different-token-entirely",
          code: first.code,
          label: "",
          expires_at: first.expires_at
        })
      end
    end

    test "a code is free again once the row holding it is revoked" do
      t = tournament()
      {:ok, first} = Mobile.create_enrollment(t.id)
      {:ok, _} = Mobile.revoke(first)

      assert {:ok, %Enrollment{}} =
               %Enrollment{}
               |> Ecto.Changeset.change(
                 tournament_id: t.id,
                 token: "another-token-entirely",
                 code: first.code,
                 label: "",
                 expires_at: first.expires_at
               )
               |> Repo.insert()
    end

    test "concurrent creations never produce two active rows with one code" do
      t = tournament()

      owner = self()

      results =
        1..25
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
            Mobile.create_enrollment(t.id)
          end,
          max_concurrency: 25,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %Enrollment{}}, &1))

      codes = Enum.map(results, fn {:ok, e} -> e.code end)
      assert length(Enum.uniq(codes)) == 25
    end
  end

  describe "lookup" do
    test "finds an active enrollment by code and by token" do
      {:ok, e} = Mobile.create_enrollment(tournament().id)

      assert %Enrollment{id: id} = Mobile.get_active_by_code(e.code)
      assert Mobile.get_active_by_token(e.token).id == id
      assert Mobile.get_active(id).id == id
    end

    test "two active rows with one code answer the newest instead of raising" do
      # The second line of defence, and the reason it exists: this read is
      # reached by the PUBLIC `POST /m` with nothing on the path to rescue
      # it, and `Repo.one` answers a second row by raising
      # `Ecto.MultipleResultsError` - a 500 anyone could ask for.
      #
      # The partial unique index makes that pair impossible, so the index is
      # dropped here to reproduce a database that has drifted anyway (a
      # restored backup, a hand-edited row). The sandbox transaction rolls
      # the DDL back with everything else.
      t = tournament()
      {:ok, first} = Mobile.create_enrollment(t.id)

      Repo.query!("DROP INDEX mobile_enrollments_active_code_index")

      second =
        Repo.insert!(%Enrollment{
          tournament_id: t.id,
          token: "a-second-token",
          code: first.code,
          label: "",
          expires_at: first.expires_at
        })

      assert %Enrollment{id: id} = Mobile.get_active_by_code(first.code)
      assert id == second.id
    end

    test "ignores non-numeric / unknown codes and tokens" do
      assert Mobile.get_active_by_code("abc") == nil
      assert Mobile.get_active_by_code("") == nil
      assert Mobile.get_active_by_code("000000") == nil
      assert Mobile.get_active_by_token("nope") == nil
    end
  end

  describe "revoke and expiry exclude an enrollment" do
    test "a revoked enrollment is no longer active" do
      {:ok, e} = Mobile.create_enrollment(tournament().id)
      {:ok, _} = Mobile.revoke(e)

      assert Mobile.get_active_by_code(e.code) == nil
      assert Mobile.get_active_by_token(e.token) == nil
      assert Mobile.get_active(e.id) == nil
    end

    test "an expired enrollment is no longer active" do
      {:ok, e} = Mobile.create_enrollment(tournament().id, ttl_hours: 1)

      past = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
      e |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert Mobile.get_active_by_code(e.code) == nil
      assert Mobile.get_active(e.id) == nil
    end
  end

  test "list_enrollments returns active ones for the tournament, newest first" do
    t = tournament()
    {:ok, _e1} = Mobile.create_enrollment(t.id)
    {:ok, e2} = Mobile.create_enrollment(t.id)
    {:ok, revoked} = Mobile.create_enrollment(t.id)
    {:ok, _} = Mobile.revoke(revoked)

    list = Mobile.list_enrollments(t.id)
    assert length(list) == 2
    assert hd(list).id == e2.id
    refute Enum.any?(list, &(&1.id == revoked.id))
  end
end
