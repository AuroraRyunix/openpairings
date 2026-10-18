defmodule PairingsEngine.RoomsTest do
  @moduledoc """
  A tournament's rooms (`PairingsEngine.Rooms`): what the checker accepts,
  what it refuses and with which word, which room a board label is in, and
  that the rooms survive the tournament's own JSON export and import.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Rooms, TournamentExport, TournamentImport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}

  defp scope do
    user =
      Repo.insert!(%User{
        email: "rooms#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Rooms", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    t
  end

  describe "normalize/1" do
    test "tidies names and boards and gives every new room an id" do
      assert {:ok, [main, annexe]} =
               Rooms.normalize([
                 %{"name" => "  Main hall ", "boards" => "1 - 5, 3-8; 9"},
                 %{"name" => "Annexe", "boards" => ""}
               ])

      assert main["name"] == "Main hall"
      assert main["boards"] == "1-9"
      assert annexe["boards"] == ""
      assert main["id"] != "" and annexe["id"] != "" and main["id"] != annexe["id"]
    end

    test "an existing room keeps its id" do
      assert {:ok, [%{"id" => "abc12345", "name" => "Renamed"}]} =
               Rooms.normalize([%{"id" => "abc12345", "name" => "Renamed", "boards" => "1-4"}])
    end

    test "names every problem, against the row it is on" do
      assert {:error, problems} =
               Rooms.normalize([
                 %{"name" => "A", "boards" => "1-10"},
                 %{"name" => "", "boards" => "20"},
                 %{"name" => "a", "boards" => "30"},
                 %{"name" => "B", "boards" => "5-12"},
                 %{"name" => "C", "boards" => "40-x"}
               ])

      assert {1, :blank_name} in problems
      assert {2, :duplicate_name} in problems
      assert {3, {:overlap, "A", 5}} in problems
      assert {4, {:boards, {:bad, "40-x"}}} in problems
    end

    test "touching ranges in two rooms are fine; sharing one board is not" do
      assert {:ok, _} =
               Rooms.normalize([
                 %{"name" => "A", "boards" => "1-10"},
                 %{"name" => "B", "boards" => "11-20"}
               ])

      assert {:error, [{1, {:overlap, "A", 10}}]} =
               Rooms.normalize([
                 %{"name" => "A", "boards" => "1-10"},
                 %{"name" => "B", "boards" => "10-20"}
               ])
    end
  end

  describe "room_for/2" do
    test "finds the room by the label's number; a board in no room is in none" do
      rooms =
        Rooms.list([
          %{"id" => "a", "name" => "Main", "boards" => "1-10"},
          %{"id" => "b", "name" => "Annexe", "boards" => "11-20, 1001"},
          %{"id" => "c", "name" => "Empty", "boards" => ""}
        ])

      assert Rooms.room_for(rooms, 3).name == "Main"
      assert Rooms.room_for(rooms, "12").name == "Annexe"
      assert Rooms.room_for(rooms, "2.3").name == "Main"
      assert Rooms.room_for(rooms, "1001/1002").name == "Annexe"
      assert Rooms.room_for(rooms, 25) == nil
      assert Rooms.names_by_board(rooms, ["1", "15", "30"]) == %{"1" => "Main", "15" => "Annexe"}
    end

    test "find_by_name/2 ignores case and spaces" do
      t = %{rooms: [%{"id" => "a", "name" => "Main hall", "boards" => "1-10"}]}
      assert Rooms.find_by_name(t, " main HALL ").id == "a"
      assert Rooms.find_by_name(t, "Annexe") == nil
      assert Rooms.find_by_name(t, "") == nil
    end
  end

  describe "the tournament" do
    test "saves rooms through its changeset and refuses ones that overlap" do
      t = tournament(scope())

      assert {:ok, t} =
               Tournaments.update_tournament(t, %{
                 "rooms" => [
                   %{"name" => "Main", "boards" => "1-20"},
                   %{"name" => "Annexe", "boards" => "21-30"}
                 ]
               })

      assert Rooms.names(t) == ["Main", "Annexe"]

      assert {:error, changeset} =
               Tournaments.update_tournament(t, %{
                 "rooms" => [
                   %{"name" => "Main", "boards" => "1-20"},
                   %{"name" => "Annexe", "boards" => "15-30"}
                 ]
               })

      assert {"board 15 is already in Main", _} = changeset.errors[:rooms]
    end

    test "rooms travel in the JSON export and come back on import" do
      scope = scope()
      t = tournament(scope, %{"rooms" => [%{"name" => "Main", "boards" => "1-12"}]})
      [%{"id" => id}] = t.rooms

      envelope = TournamentExport.export_tournament(t) |> Jason.encode!() |> Jason.decode!()

      assert [%{"tournament" => %{"rooms" => [%{"name" => "Main", "id" => ^id}]}}] =
               envelope["tournaments"]

      assert {:ok, [copy]} = TournamentImport.import(envelope, scope)
      assert [%{name: "Main", boards: "1-12", id: ^id}] = Rooms.list(copy)
    end

    test "a file from before rooms imports with none" do
      scope = scope()
      envelope = TournamentExport.export_tournament(tournament(scope)) |> Jason.encode!()

      envelope =
        envelope
        |> Jason.decode!()
        |> update_in(["tournaments", Access.at(0), "tournament"], &Map.delete(&1, "rooms"))

      assert {:ok, [copy]} = TournamentImport.import(envelope, scope)
      assert copy.rooms == []
    end
  end
end
