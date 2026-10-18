defmodule PairingsEngine.Federations.BEL.SwarMergeTest do
  @moduledoc """
  Re-uploading a `.swar` file for a tournament already here: the review
  lists what differs, and the merge writes only what the arbiter took -
  never a result or a pairing that exists here without being picked, never
  a renumbered player or a re-paired round.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Snapshots, SwarFixture, Tournaments}
  alias PairingsEngine.Federations.BEL.{SwarImport, SwarMerge}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @moduletag :tmp_dir

  defp players do
    [
      %{ni: 1, name: "Peeters, Jan", mat_fide: 205_001, elo: 2100, club: "KBSK"},
      %{ni: 2, name: "Janssens, An", mat_nat: 12_345, elo: 1950},
      %{ni: 3, name: "Maes, Piet", birth: "19800512", elo: 1800},
      %{ni: 4, name: "Claes, Els", birth: "19910203", elo: 1700}
    ]
  end

  # Round 1 played, round 2 paired without results.
  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        nb_rounds: 3,
        players: players(),
        games: [
          {1, 1, 1, 3, :white_wins},
          {1, 2, 4, 2, :draw},
          {2, 1, 2, 1, :unplayed},
          {2, 2, 3, 4, :unplayed}
        ]
      },
      overrides
    )
  end

  defp import!(dir, opts, scope) do
    path = SwarFixture.write!(dir, SwarFixture.build(opts))
    {:ok, tournament, _warnings} = SwarImport.import_file(path, scope)
    tournament
  end

  defp review!(dir, tournament, opts) do
    path = SwarFixture.write!(dir, SwarFixture.build(opts))
    {:ok, prepared} = SwarImport.prepare_import(path)
    {:ok, review} = SwarMerge.review(Repo.get!(Tournament, tournament.id), prepared)
    review
  end

  defp player_by_name(tournament, name),
    do: Repo.one!(from p in Player, where: p.tournament_id == ^tournament.id and p.name == ^name)

  defp board(tournament, round, number) do
    Repo.one!(
      from p in Pairing,
        join: r in Round,
        on: r.id == p.round_id,
        where: r.tournament_id == ^tournament.id and r.number == ^round and p.board == ^number
    )
  end

  setup do
    %{scope: user_scope_fixture()}
  end

  test "the same file again: nothing differs", %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)
    review = review!(dir, t, base())

    assert SwarMerge.identical?(review), inspect(Map.drop(review, [:file]), pretty: true)
  end

  test "results the file adds are taken by default, a new round is added, nobody is renumbered",
       %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)

    numbers_before =
      Map.new(Tournaments.list_players(t.id), &{&1.name, &1.pairing_number})

    later =
      base(%{
        players: players() ++ [%{ni: 5, name: "Wouters, Bram", elo: 1600}],
        games: [
          {1, 1, 1, 3, :white_wins},
          {1, 2, 4, 2, :draw},
          {2, 1, 2, 1, :black_wins},
          {2, 2, 3, 4, :draw},
          {3, 1, 1, 4, :white_wins},
          {3, 2, 5, 3, :black_wins}
        ],
        byes: [{3, 2, :half}]
      })

    review = review!(dir, t, later)

    assert [%{name: "Wouters, Bram", in_new_rounds?: true}] = review.new_players
    assert [%{number: 3, boards: 2, results: 2}] = review.new_rounds
    assert review.pairing_differences == []
    assert Enum.all?(review.results, & &1.added?)
    assert length(review.results) == 2

    assert {:ok, summary} = SwarMerge.apply(review, %{}, scope)
    assert summary.rows == 2
    assert summary.rounds == 1
    assert summary.new_players == 1

    assert board(t, 2, 1).result == "0-1"
    assert board(t, 2, 2).result == "1/2-1/2"
    assert board(t, 3, 2).result == "0-1"

    after_merge = Map.new(Tournaments.list_players(t.id), &{&1.name, &1.pairing_number})
    assert Map.take(after_merge, Map.keys(numbers_before)) == numbers_before
    assert after_merge["Wouters, Bram"] == 5
    assert player_by_name(t, "Wouters, Bram").start_round == 3

    assert [%{type: "requested-half"}] = Tournaments.list_byes_for_round(t.id, 3)

    assert [%{trigger: "import.swar_merge", pinned: true} | _] = Snapshots.list(t.id)
  end

  test "a result entered here that the file has differently is a conflict, kept unless picked",
       %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)

    {:ok, _} =
      Tournaments.update_pairing_result(board(t, 1, 2), "1-0", acknowledged: [:result_correction])

    review = review!(dir, t, base())

    assert [
             %{kind: :result, round: 1, board: 2, here: "1-0", file: "1/2-1/2", added?: false} =
               row
           ] =
             review.results

    assert {:ok, _} = SwarMerge.apply(review, %{}, scope)
    assert board(t, 1, 2).result == "1-0"

    review = review!(dir, t, base())
    assert {:ok, _} = SwarMerge.apply(review, %{rows: %{row.id => :file}}, scope)
    assert board(t, 1, 2).result == "1/2-1/2"
  end

  test "a round paired differently is reported and never re-paired", %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)

    other =
      base(%{
        games: [
          {1, 1, 1, 3, :white_wins},
          {1, 2, 4, 2, :draw},
          {2, 1, 1, 4, :unplayed},
          {2, 2, 2, 3, :unplayed}
        ]
      })

    review = review!(dir, t, other)

    assert [%{round: 2, here: here, file: file}] = review.pairing_differences
    assert length(here) == 2 and length(file) == 2

    before = Repo.all(from p in Pairing, select: {p.id, p.white_player_id, p.black_player_id})
    assert {:ok, _} = SwarMerge.apply(review, %{}, scope)

    assert Repo.all(from p in Pairing, select: {p.id, p.white_player_id, p.black_player_id}) ==
             before
  end

  test "settings and player details: listed, kept by default, taken when chosen",
       %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)

    changed =
      base(%{
        tournament: %{city: "Elsewhere"},
        players: List.update_at(players(), 0, &Map.put(&1, :club, "Other Club"))
      })

    review = review!(dir, t, changed)

    assert [%{field: :city, here: "Fixtureville", file: "Elsewhere", locked?: false}] =
             review.settings

    assert [%{name: "Peeters, Jan", changes: [%{field: :club, file: "Other Club"}]}] =
             review.player_changes

    assert {:ok, _} = SwarMerge.apply(review, %{}, scope)
    assert Repo.get!(Tournament, t.id).city == "Fixtureville"
    assert player_by_name(t, "Peeters, Jan").club == "KBSK"

    review = review!(dir, t, changed)
    assert {:ok, _} = SwarMerge.apply(review, %{settings: :file, players: :file}, scope)
    assert Repo.get!(Tournament, t.id).city == "Elsewhere"
    assert player_by_name(t, "Peeters, Jan").club == "Other Club"
  end

  test "players are matched on FIDE id, national id, then name and birth year",
       %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)

    renamed =
      base(%{
        players: [
          %{ni: 1, name: "Peeters, Johannes", mat_fide: 205_001, elo: 2100, club: "KBSK"},
          %{ni: 2, name: "Janssens-Smet, An", mat_nat: 12_345, elo: 1950},
          %{ni: 3, name: "Piet MAES", birth: "19800512", elo: 1800},
          %{ni: 4, name: "Claes, Els", birth: "19920203", elo: 1700}
        ]
      })

    review = review!(dir, t, renamed)

    names = Enum.map(review.player_changes, & &1.name) |> Enum.sort()
    assert "Peeters, Jan" in names
    assert "Janssens, An" in names
    # A different year of birth is a different person: Els is new, and the
    # one here is not in the file.
    assert [%{name: "Claes, Els"}] = review.new_players
    assert [%{name: "Claes, Els"}] = review.only_here_players
  end

  test "rounds that need a new player cannot be added without them", %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)

    later =
      base(%{
        players: players() ++ [%{ni: 5, name: "Wouters, Bram"}],
        games: base().games ++ [{3, 1, 5, 1, :draw}]
      })

    review = review!(dir, t, later)

    assert {:error, :rounds_need_new_players} =
             SwarMerge.apply(review, %{new_players: :skip}, scope)

    assert {:ok, %{rounds: 0}} =
             SwarMerge.apply(review, %{new_players: :skip, rounds: :skip}, scope)
  end

  test "a tournament that changed after the review is refused", %{tmp_dir: dir, scope: scope} do
    t = import!(dir, base(), scope)
    review = review!(dir, t, base(%{tournament: %{city: "Elsewhere"}}))

    {:ok, _} = Tournaments.update_pairing_result(board(t, 2, 1), "1-0")

    assert {:error, :changed_since_review} = SwarMerge.apply(review, %{settings: :file}, scope)
    assert Repo.get!(Tournament, t.id).city == "Fixtureville"
    assert SwarMerge.error_message(:changed_since_review) =~ "changed"
  end

  @tag :swar_fixture
  test "a real file against its own import, with one result changed here",
       %{scope: scope} do
    {:ok, prepared} = SwarImport.prepare_import("test/fixtures/problemski.swar")
    {:ok, t, _warnings} = SwarImport.commit_import(prepared, %{}, scope)

    pairing =
      Repo.one!(
        from p in Pairing,
          join: r in Round,
          on: r.id == p.round_id,
          where: r.tournament_id == ^t.id and r.number == 1 and not is_nil(p.black_player_id),
          order_by: p.board,
          limit: 1
      )

    other = if pairing.result == "1-0", do: "0-1", else: "1-0"
    {:ok, _} = Tournaments.update_pairing_result(pairing, other)

    {:ok, review} = SwarMerge.review(Repo.get!(Tournament, t.id), prepared)

    assert [%{pairing_id: id, here: ^other, added?: false}] = review.results
    assert id == pairing.id
    assert review.settings == []
    assert review.player_changes == []
    assert review.pairing_differences == []
  end

  @tag :swar_fixture
  test "every real file compares as identical with its own import", %{scope: scope} do
    for path <-
          ~w(test/fixtures/problemski.swar test/fixtures/c-reeks.swar test/fixtures/test3-321.swar) do
      {:ok, prepared} = SwarImport.prepare_import(path)
      {:ok, t, _warnings} = SwarImport.commit_import(prepared, %{}, scope)
      {:ok, review} = SwarMerge.review(Repo.get!(Tournament, t.id), prepared)

      assert SwarMerge.identical?(review), "#{path}: #{inspect(Map.drop(review, [:file]))}"
    end
  end
end
