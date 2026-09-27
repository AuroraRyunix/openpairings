defmodule PairingsEngine.Federations.BEL.SwarBackupTest do
  @moduledoc """
  A JSON backup of a tournament that came from SWAR, restored, is that
  tournament: the SWAR export of the restored copy is byte for byte the
  export of the original, and a round robin continued from it keeps SWAR's
  full-point free round. Old backups, from before the SWAR bookkeeping
  travelled, still restore.
  """

  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Repo, RoundRobin, SwarFixture, TournamentExport, TournamentImport}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Tournaments.{Pairing, Tournament}

  @moduletag :tmp_dir

  setup do
    user = PairingsEngine.AccountsFixtures.user_fixture()
    %{scope: Scope.for_user(user)}
  end

  defp import_swar!(dir, opts, scope) do
    path = SwarFixture.write!(dir, SwarFixture.build(opts))
    assert {:ok, t, _warnings} = SwarImport.import_file(path, scope)
    Repo.reload!(t)
  end

  # A real backup: the envelope through JSON and back, into a new row - on
  # a machine where the original is not (its guid is taken off the
  # original's row first, as if it lived elsewhere; a caller comparing
  # exports takes the original's before that).
  defp backup_and_restore!(tournament, scope, edit \\ & &1) do
    envelope =
      tournament
      |> TournamentExport.export_tournament()
      |> Jason.encode!()
      |> Jason.decode!()
      |> edit.()

    Repo.update_all(from(t in Tournament, where: t.id == ^tournament.id), set: [swar_guid: nil])

    assert {:ok, [copy], []} = TournamentImport.import_with_notes(envelope, scope)
    Repo.reload!(copy)
  end

  defp round_robin_opts do
    %{
      nb_rounds: 3,
      tournament: %{type: 4, guid: "{RR-GUID-1}"},
      tiebreaks: [8, 10, 6, 9, 14],
      players: [
        %{ni: 1, name: "R2", rank: 2},
        %{ni: 2, name: "R1", rank: 1},
        %{ni: 3, name: "R3", rank: 3}
      ]
    }
  end

  defp swiss_opts do
    %{
      nb_rounds: 2,
      tournament: %{guid: "{SWISS-GUID-1}", elo_used: 2, first_table: 5},
      xtra_points: [{4, 2000}],
      exclusion: {0, "1,2:3,4"},
      categories: {3, ["-12", "-16"], ["-1400", "-1800"]},
      tiebreaks: [3, 4, 11, 6, 15],
      players: [
        %{ni: 1, extra_pts: 4, cat_index: 101},
        %{ni: 2, cat_index: 102},
        %{ni: 3, extra_pts: 2, cat_index: 201},
        %{ni: 4, cat_index: 202}
      ],
      games: [{1, 1, 1, 3, :white_wins}, {1, 2, 2, 4, :draw}]
    }
  end

  test "a SWAR round robin: the restored copy exports the same file", %{
    tmp_dir: dir,
    scope: scope
  } do
    original = import_swar!(dir, round_robin_opts(), scope)
    exported = SwarExport.export(original.id)
    copy = backup_and_restore!(original, scope)

    assert copy.id != original.id
    assert copy.swar_guid == "{RR-GUID-1}"
    assert copy.swar_settings == original.swar_settings
    assert SwarExport.export(copy.id) == exported
  end

  test "a restored SWAR round robin keeps SWAR's full-point free round", %{
    tmp_dir: dir,
    scope: scope
  } do
    copy = dir |> import_swar!(round_robin_opts(), scope) |> backup_and_restore!(scope)

    assert {:ok, 3} = RoundRobin.pair_all_rounds(copy)

    byes =
      from(p in Pairing,
        join: r in assoc(p, :round),
        where: r.tournament_id == ^copy.id and is_nil(p.black_player_id)
      )
      |> Repo.all()

    assert length(byes) == 3
    assert Enum.all?(byes, &(&1.result == "bye"))
    assert PairingsEngine.Tournaments.list_byes_for_round(copy.id, 1) == []
  end

  test "a Swiss with extra points, exclusions and two-axis categories", %{
    tmp_dir: dir,
    scope: scope
  } do
    original = import_swar!(dir, swiss_opts(), scope)
    assert original.count_extra_points
    assert original.swar_category_type == 3
    exported = SwarExport.export(original.id)

    copy = backup_and_restore!(original, scope)

    assert copy.swar_category_type == 3
    assert copy.swar_category_axis2 == original.swar_category_axis2
    assert SwarExport.export(copy.id) == exported
  end

  test "beside a tournament that already has its SWAR identity, a backup imports without it",
       %{tmp_dir: dir, scope: scope} do
    original = import_swar!(dir, swiss_opts(), scope)

    envelope =
      original |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

    # Any owner: somebody else imports it here.
    other = Scope.for_user(PairingsEngine.AccountsFixtures.user_fixture())
    assert {:ok, [copy], [note]} = TournamentImport.import_with_notes(envelope, other)
    assert note =~ "without its SWAR identity"

    copy = Repo.reload!(copy)
    assert copy.swar_guid in [nil, ""]
    assert copy.swar_settings == original.swar_settings
    assert Repo.reload!(original).swar_guid == "{SWISS-GUID-1}"

    # The copy's first export mints an identity of its own.
    SwarExport.export(copy.id)
    refute Repo.reload!(copy).swar_guid in [nil, "", "{SWISS-GUID-1}"]
  end

  test "categories ranked separately travel in a backup", %{tmp_dir: dir, scope: scope} do
    original =
      import_swar!(
        dir,
        %{
          tournament: %{cat_separes: 1},
          categories: {5, ["A", "B"], []},
          players: [%{ni: 1, cat_index: 100}, %{ni: 2, cat_index: 200}]
        },
        scope
      )

    assert original.categories_ranked_separately
    assert backup_and_restore!(original, scope).categories_ranked_separately
  end

  test "a backup from before the SWAR bookkeeping travelled still restores", %{
    tmp_dir: dir,
    scope: scope
  } do
    original = import_swar!(dir, swiss_opts(), scope)

    old_backup = fn envelope ->
      update_in(envelope, ["tournaments", Access.at(0), "tournament"], fn t ->
        Map.drop(t, ~w(swar_guid swar_settings swar_category_type swar_category_axis2
                       categories_ranked_separately))
      end)
    end

    copy = backup_and_restore!(original, scope, old_backup)

    assert copy.swar_settings == %{}
    assert copy.swar_category_type == nil
    refute copy.categories_ranked_separately
    assert copy.swar_guid in [nil, ""]
    # It still exports - a new guid, and SWAR's defaults where the file's
    # own settings were.
    assert {:ok, _parsed} = copy.id |> SwarExport.export() |> SwarImport.parse()
  end

  test "restoring a restore point never takes away a guid minted since", %{
    tmp_dir: dir,
    scope: scope
  } do
    original = import_swar!(dir, swiss_opts(), scope)

    entry =
      original
      |> TournamentExport.export_tournament()
      |> Jason.encode!()
      |> Jason.decode!()
      |> get_in(["tournaments", Access.at(0)])
      |> put_in(["tournament", "swar_guid"], nil)
      |> Map.put("rounds", [])
      |> Map.put("byes", [])
      |> Map.put("forbidden_pairings", [])

    # `restore_into!/2` wipes nothing itself (`Snapshots.restore/3` does
    # that first); only the tournament row matters here.
    {:ok, restored} =
      Repo.transaction(fn ->
        Repo.delete_all(
          from(p in PairingsEngine.Tournaments.Player, where: p.tournament_id == ^original.id)
        )

        TournamentImport.restore_into!(Repo.get!(Tournament, original.id), entry)
      end)

    assert Repo.reload!(restored).swar_guid == "{SWISS-GUID-1}"
    assert Repo.reload!(restored).swar_settings == original.swar_settings
  end
end
