defmodule PairingsEngine.ByeTypesTest do
  @moduledoc """
  "Ask the bye type for each absence": off, the absence value decides what
  a round sat out is worth; on, the player dialog's pick is stored as the
  typed `byes` row and lives through pairing, unpairing, export and
  re-import exactly as an imported bye does.
  """

  # async: false - the TRF import writes in a real transaction.
  use PairingsEngine.DataCase, async: false

  alias Ainalrami.Trf
  alias PairingsEngine.{ByeTypes, Pairing, Repo, Standings, TrfExport, TrfImport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp game(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  @names ~w(Alpha Bravo Charlie Delta Echo Foxtrot)

  # Six players, round 1 played, round 2 not paired.
  defp tournament(attrs) do
    games = %{
      1 => game(4, "w", "1"),
      2 => game(5, "w", "="),
      3 => game(6, "w", "0"),
      4 => game(1, "b", "0"),
      5 => game(2, "b", "="),
      6 => game(3, "b", "1")
    }

    players =
      for {rank, g} <- Enum.sort(games) do
        %{
          rank: rank,
          name: "#{Enum.at(@names, rank - 1)}, Player",
          points: Trf.points_for_game(g),
          games: [g]
        }
      end

    text =
      Trf.serialize(
        %{
          tournament: %{name: "Bye types", type: "swiss", number_of_rounds: 5},
          players: players
        },
        dialect: :trf26
      )

    assert {:ok, t, []} = TrfImport.import_text(text, user_scope())

    t
    |> Ecto.Changeset.change(
      Map.merge(%{round_dates: for(n <- 1..5, do: "2026-03-0#{n}"), ask_bye_type: true}, attrs)
    )
    |> Repo.update!()
  end

  defp by_name(t),
    do: Map.new(Tournaments.list_players(t.id), &{hd(String.split(&1.name, ",")), &1})

  defp byes(t, round) do
    t.id
    |> Tournaments.list_byes_for_round(round)
    |> Map.new(&{hd(String.split(&1.player.name, ",")), &1.type})
  end

  defp seated(t, number) do
    round =
      Repo.one!(
        from r in PairingsEngine.Tournaments.Round,
          where: r.tournament_id == ^t.id and r.number == ^number,
          preload: :pairings
      )

    round.pairings
    |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
    |> Enum.reject(&is_nil/1)
  end

  describe "the pre-picked answer" do
    for {abs_value, type} <- [
          {0.5, "requested-half"},
          {1.0, "full-point"},
          {nil, "requested-zero"},
          {0.0, "requested-zero"}
        ] do
      test "an absence worth #{inspect(abs_value)} is offered as #{type}" do
        t = tournament(%{abs_value: unquote(abs_value)})
        delta = by_name(t)["Delta"]

        assert ByeTypes.dialog_types(t, delta, "1,2,4") == %{
                 2 => unquote(type),
                 4 => unquote(type)
               }
      end
    end

    test "picked byes use none of the paid-absences allowance up" do
      t = tournament(%{abs_value: 0.5, abs_nbfois: 1})
      delta = by_name(t)["Delta"]

      # Round 2 is about to be a picked bye, not an absence, so round 4 is
      # still the first absence as far as the count cap goes.
      assert ByeTypes.dialog_types(t, delta, "2,4") == %{
               2 => "requested-half",
               4 => "requested-half"
             }

      assert {:ok, delta} =
               Tournaments.update_player(
                 delta,
                 %{"absent_rounds" => "2", "bye_types" => %{"2" => "requested-half"}},
                 []
               )

      assert ByeTypes.dialog_types(t, delta, "2,4") == %{
               2 => "requested-half",
               4 => "requested-half"
             }
    end

    test "the limits still decide the pre-picked answer, and a richer pick is flagged" do
      t = tournament(%{abs_value: 0.5, abs_jusque: 1})
      delta = by_name(t)["Delta"]

      assert ByeTypes.dialog_types(t, delta, "2") == %{2 => "requested-zero"}
      assert ByeTypes.above_limits?(t, 2, 1, "requested-half")
      refute ByeTypes.above_limits?(t, 2, 1, "requested-zero")

      # No limit cut anything: nothing to say.
      t = %{t | abs_jusque: nil}
      refute ByeTypes.above_limits?(t, 2, 1, "full-point")
    end

    test "a player not eligible for half-point byes is offered the zero" do
      t = tournament(%{abs_value: 0.5})
      delta = by_name(t)["Delta"] |> Ecto.Changeset.change(no_half_bye: true) |> Repo.update!()
      assert ByeTypes.dialog_types(t, delta, "2") == %{2 => "requested-zero"}
    end

    test "a stored type wins over the absence value" do
      t = tournament(%{abs_value: 0.5})
      delta = by_name(t)["Delta"]

      assert {:ok, delta} =
               Tournaments.update_player(delta, %{
                 "absent_rounds" => "2",
                 "bye_types" => %{"2" => "requested-zero"}
               })

      assert ByeTypes.dialog_types(t, delta, "2") == %{2 => "requested-zero"}
    end

    test "nothing is asked with the setting off" do
      t = tournament(%{abs_value: 0.5, ask_bye_type: false})
      assert ByeTypes.dialog_types(t, by_name(t)["Delta"], "2") == %{}
    end
  end

  test "off: the pick is ignored and the absence value decides, as before" do
    t = tournament(%{abs_value: 0.5, ask_bye_type: false})

    assert {:ok, _} =
             Tournaments.update_player(by_name(t)["Delta"], %{
               "absent_rounds" => "2",
               "bye_types" => %{"2" => "requested-zero"}
             })

    assert byes(t, 2) == %{}
    assert {:ok, text} = TrfExport.export(Repo.reload!(t))
    assert text =~ ~r/^240 H 002\s+4\s*$/m
  end

  # A zero-point bye in a tournament that pays half a point for an absence:
  # the one case where the answer differs from the absence value, so the
  # one that shows the row is what is used.
  test "on: the picked bye pairs, unpairs, exports and re-imports as picked" do
    t = tournament(%{abs_value: 0.5})
    delta = by_name(t)["Delta"]

    assert {:ok, _} =
             Tournaments.update_player(delta, %{
               "absent_rounds" => "2",
               "bye_types" => %{"2" => "requested-zero"}
             })

    assert byes(t, 2) == %{"Delta" => "requested-zero"}

    assert {:ok, text} = TrfExport.export(Repo.reload!(t))
    assert text =~ ~r/^240 Z 002\s+4\s*$/m

    assert {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
    refute delta.id in seated(t, 2)
    assert byes(t, 2) == %{"Delta" => "requested-zero"}
    # Lost round 1, zero-point bye in round 2.
    assert Standings.points_by_player(Repo.reload!(t))[delta.id] == 0.0

    assert :ok = Pairing.delete_round(t.id, 2)
    assert byes(t, 2) == %{"Delta" => "requested-zero"}

    assert {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
    assert byes(t, 2) == %{"Delta" => "requested-zero"}

    assert :ok = Pairing.delete_round(t.id, 2)
    assert {:ok, text} = TrfExport.export(Repo.reload!(t))
    assert {:ok, again, []} = TrfImport.import_text(text, user_scope())
    assert byes(again, 2) == %{"Delta" => "requested-zero"}
    assert by_name(again)["Delta"].absent_rounds == "2"
  end

  test "on: a full-point bye is an F, with its ### line once the round is paired" do
    t = tournament(%{abs_value: nil})
    delta = by_name(t)["Delta"]

    assert {:ok, _} =
             Tournaments.update_player(delta, %{
               "absent_rounds" => "2",
               "bye_types" => %{"2" => "full-point"}
             })

    assert {:ok, text} = TrfExport.export(Repo.reload!(t))
    assert text =~ ~r/^240 F 002\s+4\s*$/m

    assert {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
    assert byes(t, 2) == %{"Delta" => "full-point"}
    assert Standings.points_by_player(Repo.reload!(t))[delta.id] == 1.0

    assert {:ok, text} = TrfExport.export(Repo.reload!(t))
    assert text =~ "### FPB @ Round 2: 4=FPB"
  end

  test "changing the pick replaces the row; taking the round out drops it" do
    t = tournament(%{abs_value: 0.5})
    delta = by_name(t)["Delta"]

    assert {:ok, delta} =
             Tournaments.update_player(delta, %{
               "absent_rounds" => "2",
               "bye_types" => %{"2" => "requested-zero"}
             })

    assert {:ok, delta} =
             Tournaments.update_player(delta, %{
               "absent_rounds" => "2",
               "bye_types" => %{"2" => "requested-half"}
             })

    assert byes(t, 2) == %{"Delta" => "requested-half"}

    assert {:ok, _} = Tournaments.update_player(delta, %{"absent_rounds" => ""})
    assert byes(t, 2) == %{}
  end

  test "a pick for a paired round, or a round not in the absences, writes nothing" do
    t = tournament(%{abs_value: 0.5})
    delta = by_name(t)["Delta"]

    assert {:ok, _} =
             Tournaments.update_player(delta, %{
               "absent_rounds" => "3",
               "bye_types" => %{"1" => "full-point", "2" => "full-point", "x" => "full-point"}
             })

    assert Repo.all(from b in "byes", where: b.tournament_id == ^t.id, select: b.round) == []
  end

  test "a type that is not one of the three is dropped" do
    assert ByeTypes.parse(%{"2" => "pairing-allocated", "3" => "absent", "4" => "full-point"}) ==
             %{4 => "full-point"}
  end

  describe "the half-point bye rules (Q174-Q176) see the pick" do
    test "a picked half-point bye for an ineligible player is refused" do
      t = tournament(%{abs_value: nil})
      delta = by_name(t)["Delta"] |> Ecto.Changeset.change(no_half_bye: true) |> Repo.update!()

      assert {:error, changeset} =
               Tournaments.update_player(delta, %{
                 "absent_rounds" => "2",
                 "bye_types" => %{"2" => "requested-half"}
               })

      assert {msg, _} = changeset.errors[:absent_rounds]
      assert msg =~ "not eligible for half-point byes"
      assert byes(t, 2) == %{}
      assert Repo.reload!(delta).absent_rounds == ""

      # A zero-point bye is fine, even where an absence would pay half.
      assert {:ok, _} =
               Tournaments.update_player(delta, %{
                 "absent_rounds" => "2",
                 "bye_types" => %{"2" => "requested-zero"}
               })
    end

    test "a second picked half-point bye asks for confirmation, a zero-point one does not" do
      t = tournament(%{abs_value: nil})
      delta = by_name(t)["Delta"]

      assert {:ok, delta} =
               Tournaments.update_player(
                 delta,
                 %{"absent_rounds" => "2", "bye_types" => %{"2" => "requested-half"}},
                 []
               )

      attrs = %{
        "absent_rounds" => "2,4",
        "bye_types" => %{"2" => "requested-half", "4" => "requested-half"}
      }

      assert Tournaments.second_half_bye_rounds(delta, attrs) == [4]

      assert {:error, {:needs_acknowledgement, [:second_half_bye]}} =
               Tournaments.update_player(delta, attrs, [])

      zero = put_in(attrs, ["bye_types", "4"], "requested-zero")
      assert Tournaments.second_half_bye_rounds(delta, zero) == []
      assert {:ok, _} = Tournaments.update_player(delta, zero, [])
      assert byes(t, 4) == %{"Delta" => "requested-zero"}
    end

    test "a stored zero-point bye is not counted as a half-point one" do
      t = tournament(%{abs_value: 0.5})
      delta = by_name(t)["Delta"]

      assert {:ok, delta} =
               Tournaments.update_player(
                 delta,
                 %{"absent_rounds" => "2", "bye_types" => %{"2" => "requested-zero"}},
                 []
               )

      assert Tournaments.second_half_bye_rounds(delta, %{
               "absent_rounds" => "2,4",
               "bye_types" => %{"2" => "requested-zero", "4" => "requested-half"}
             }) == []
    end
  end
end
