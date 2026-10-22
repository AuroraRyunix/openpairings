defmodule PairingsEngine.QuotasTest do
  @moduledoc """
  What one account may pile onto the hosted server: a ceiling on the
  tournaments it owns, checked on every way a tournament is born, and an
  hourly allowance of imports. None of it on a desktop install.
  """
  # Changes the application's environment (the ceiling, local mode).
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Quotas, RateLimit, Tournaments, TournamentExport, TournamentImport}

  setup do
    local = Application.get_env(:pairings_engine, :local_mode)
    max = Application.get_env(:pairings_engine, :max_tournaments_per_account)

    on_exit(fn ->
      Application.put_env(:pairings_engine, :local_mode, local)

      if max,
        do: Application.put_env(:pairings_engine, :max_tournaments_per_account, max),
        else: Application.delete_env(:pairings_engine, :max_tournaments_per_account)
    end)

    Application.put_env(:pairings_engine, :local_mode, false)
    Application.put_env(:pairings_engine, :max_tournaments_per_account, 2)
    {:ok, scope: user_scope_fixture()}
  end

  defp create(scope, name),
    do: Tournaments.create_tournament(scope, %{"name" => name, "type" => "swiss"})

  describe "the tournament ceiling" do
    test "creating stops at the ceiling, and the bin does not count", %{scope: scope} do
      assert {:ok, first} = create(scope, "One")
      assert {:ok, _} = create(scope, "Two")
      assert {:error, :tournament_quota} = create(scope, "Three")

      # Deleting one makes room: the recycle bin empties itself.
      {:ok, _} = Tournaments.soft_delete_tournament(first)
      assert {:ok, _} = create(scope, "Three")
    end

    test "it is per account", %{scope: scope} do
      {:ok, _} = create(scope, "One")
      {:ok, _} = create(scope, "Two")
      assert {:ok, _} = create(user_scope_fixture(), "Somebody else's")
    end

    test "an import has to fit as a whole", %{scope: scope} do
      {:ok, t} = create(scope, "One")
      {:ok, _} = create(scope, "Two")
      envelope = TournamentExport.export_tournament(t)

      assert {:error, message} = TournamentImport.import(envelope, scope)
      assert message == Quotas.message(:tournament_quota)
      assert length(Tournaments.list_tournaments(scope)) == 2
    end

    test "a TRF import is refused before it is read into the database", %{scope: scope} do
      {:ok, _} = create(scope, "One")
      {:ok, _} = create(scope, "Two")

      trf =
        Ainalrami.Trf.serialize(
          %{
            tournament: %{name: "Over the ceiling", type: "swiss", number_of_rounds: 5},
            players:
              for(rank <- 1..4, do: %{rank: rank, name: "Player, #{rank}", points: 0, games: []})
          },
          dialect: :trf26
        )

      assert {:error, reason} = PairingsEngine.TrfImport.import_text(trf, scope)
      assert PairingsEngine.TrfImport.error_message(reason) == Quotas.message(:tournament_quota)
    end

    test "a desktop install has no ceiling", %{scope: scope} do
      Application.put_env(:pairings_engine, :local_mode, true)

      for n <- 1..3, do: assert({:ok, _} = create(scope, "T#{n}"))
      assert Quotas.max_tournaments() == :infinity
    end
  end

  describe "the import allowance" do
    test "counts per account per hour, and refuses past it", %{scope: scope} do
      key = Integer.to_string(scope.user.id)
      # The bucket lives in ETS, outside the sandbox, and SQLite hands a
      # rolled-back id to the next user: an earlier test's imports can be
      # sitting in "our" bucket. Start from nothing.
      RateLimit.clear(:tournament_import, key)
      on_exit(fn -> RateLimit.clear(:tournament_import, key) end)

      for _ <- 1..20, do: assert(:ok = Quotas.check_import(scope))
      assert {:error, :import_quota} = Quotas.check_import(scope)

      # Somebody else's allowance is their own.
      assert :ok = Quotas.check_import(user_scope_fixture())
    end

    test "a desktop install is not counted", %{scope: scope} do
      Application.put_env(:pairings_engine, :local_mode, true)
      for _ <- 1..25, do: assert(:ok = Quotas.check_import(scope))
    end
  end
end
