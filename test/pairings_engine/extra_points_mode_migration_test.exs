defmodule PairingsEngine.ExtraPointsModeMigrationTest do
  @moduledoc """
  Which existing tournaments the extra-points-mode migration turns into
  acceleration (`20260927160856_add_extra_points_mode.exs`): a SWAR
  tournament that uses extra points and has no bands of this app's own.
  Runs the migration's own statement, not a copy of it, against rows made
  here - and the same rule for a JSON backup written before the mode
  existed (`TournamentImport`).
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, TournamentImport, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  @migration "priv/repo/migrations/20260927160856_add_extra_points_mode.exs"
  @migration_module PairingsEngine.Repo.Migrations.AddExtraPointsMode

  setup_all do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration)
    end

    :ok
  end

  defp tournament(attrs, extra_points \\ 0.0) do
    t =
      Repo.insert!(struct(%Tournament{name: "Old", type: "swiss", rounds_count: 5}, attrs))

    {:ok, _} =
      Tournaments.create_player(t.id, %{"name" => "A", "extra_points" => extra_points})

    t
  end

  defp migrate! do
    # `apply/3`: the module is loaded from the file at run time, so the
    # compiler cannot see it.
    Repo.query!(apply(@migration_module, :backfill_sql, []))
  end

  test "SWAR tournaments using extra points become acceleration; the rest stay handicap" do
    by_guid = tournament(%{swar_guid: "{G-1}"}, 1.0)
    by_settings = tournament(%{swar_settings: %{"elo_used" => 1}, count_extra_points: true})
    swar_unused = tournament(%{swar_guid: "{G-2}"})
    native_with_bands = tournament(%{swar_guid: "{G-3}", extra_points_bands: "1400:1"}, 1.0)
    native = tournament(%{count_extra_points: true}, 1.0)

    migrate!()

    mode = &Repo.reload!(&1).extra_points_mode
    assert mode.(by_guid) == "acceleration"
    assert mode.(by_settings) == "acceleration"
    assert mode.(swar_unused) == "handicap"
    assert mode.(native_with_bands) == "handicap"
    assert mode.(native) == "handicap"
  end

  test "a backup written before the mode existed gets the same answer on import" do
    user =
      Repo.insert!(%PairingsEngine.Accounts.User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    scope = PairingsEngine.Accounts.Scope.for_user(user)

    entry = fn tournament_attrs ->
      %{
        "tournament" =>
          Map.merge(
            %{"name" => "Backup", "type" => "swiss", "rounds_count" => 5},
            tournament_attrs
          ),
        "players" => [%{"id" => 1, "name" => "A", "extra_points" => 1.0}]
      }
    end

    payload = %{
      "format" => "openpairings-export",
      "version" => 1,
      "tournaments" => [
        entry.(%{"swar_guid" => "{B-1}"}),
        entry.(%{"extra_points_bands" => "1400:1"}),
        entry.(%{"swar_guid" => "{B-2}", "extra_points_mode" => "handicap"})
      ]
    }

    assert {:ok, [a, b, c]} = TournamentImport.import(payload, scope)
    assert Repo.reload!(a).extra_points_mode == "acceleration"
    assert Repo.reload!(b).extra_points_mode == "handicap"
    assert Repo.reload!(c).extra_points_mode == "handicap"
  end
end
