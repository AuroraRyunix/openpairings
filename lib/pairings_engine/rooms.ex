defmodule PairingsEngine.Rooms do
  @moduledoc """
  The rooms of a playing hall: a tournament's `rooms`, each a name and the
  board numbers it holds, written the way `PairingsEngine.BoardRanges`
  reads them ("1-20, 35, 40-45").

  Stored on the tournament as a JSON list of `%{"id", "name", "boards"}`.
  The `id` is a short random string handed out on the first save and kept
  through every rename after it, so whatever points at a room (a print
  station, a hall announcer) still points at it when somebody decides
  "Hall B" was always the "Annexe". `boards` is kept in the reader's own
  spelling: what you typed, tidied.

  The rules, enforced by `normalize/1` (and so by `Tournament.changeset/2`,
  whoever writes): a name, at most 60 characters, unique in the
  tournament without regard to case; boards that read; and no board in two
  rooms. A board in no room is fine - it is simply not in one - and a room
  with no boards yet is fine too, it just holds nothing.
  """

  alias PairingsEngine.BoardRanges

  @name_max 60
  @max_rooms 50

  @type room :: %{
          id: String.t(),
          name: String.t(),
          boards: String.t(),
          ranges: [BoardRanges.range()]
        }

  @type problem ::
          :blank_name
          | :name_too_long
          | :duplicate_name
          | {:boards, {atom(), String.t()}}
          | {:overlap, String.t(), pos_integer()}
          | :too_many

  @doc "Longest name a room may have."
  def name_max, do: @name_max

  @doc "Most rooms a tournament may have."
  def max_rooms, do: @max_rooms

  @doc """
  The tournament's rooms, in its order, as `%{id:, name:, boards:, ranges:}`.
  Takes a tournament or the stored list itself. A stored entry that no
  longer reads (nothing writes one, but files are files) holds no boards.
  """
  @spec list(map() | list() | nil) :: [room()]
  def list(%{rooms: rooms}), do: list(rooms)
  def list(nil), do: []

  def list(rooms) when is_list(rooms) do
    for %{} = r <- rooms do
      boards = text(r, "boards")

      ranges =
        case BoardRanges.parse(boards) do
          {:ok, ranges} -> ranges
          {:error, _} -> []
        end

      %{id: text(r, "id"), name: text(r, "name"), boards: boards, ranges: ranges}
    end
  end

  @doc "Whether the tournament has any room at all."
  def any?(tournament), do: list(tournament) != []

  @doc "The rooms' names, in order."
  def names(tournament), do: Enum.map(list(tournament), & &1.name)

  @doc "The room with id `id`, or nil."
  def get(tournament, id) when is_binary(id) and id != "",
    do: Enum.find(list(tournament), &(&1.id == id))

  def get(_tournament, _id), do: nil

  @doc """
  The room called `name`, trimmed and without regard to case, or nil. For
  a device that says where it stands in words rather than by id.
  """
  def find_by_name(tournament, name) when is_binary(name) do
    key = fold(name)
    if key == "", do: nil, else: Enum.find(list(tournament), &(fold(&1.name) == key))
  end

  def find_by_name(_tournament, _name), do: nil

  @doc """
  The room board `label` is in (a label as the pairing list prints it,
  `"12"`, `"3.1"`, `"1001/1002"`), or nil. Takes a tournament, its stored
  list or `list/1`'s rooms.
  """
  def room_for(rooms_or_tournament, label) do
    rooms = rooms(rooms_or_tournament)
    Enum.find(rooms, &holds?(&1, label))
  end

  @doc """
  Whether `room` holds board `label`. A room with no boards holds none -
  unlike a board filter, where nothing typed means everything.
  """
  def holds?(%{ranges: []}, _label), do: false
  def holds?(%{ranges: ranges}, label), do: BoardRanges.member?(ranges, label)

  @doc """
  `%{label => room name}` for the given board labels: what the pairing list
  and the printed sheet need, worked out once per page.
  """
  def names_by_board(rooms_or_tournament, labels) do
    rooms = rooms(rooms_or_tournament)

    if rooms == [] do
      %{}
    else
      for label <- labels, room = room_for(rooms, label), into: %{}, do: {label, room.name}
    end
  end

  defp rooms([%{ranges: _} | _] = rooms), do: rooms
  defp rooms(other), do: list(other)

  @doc """
  Checks and tidies a list of rooms as typed (maps with `"name"`, `"boards"`
  and, for a room that already exists, `"id"`; atom keys are accepted
  too). `{:ok, stored}` - names trimmed, boards rewritten in the reader's
  spelling, an id for every new room - or `{:error, problems}`, a list of
  `{index, problem}` with every problem found, so a page can put each one
  beside the row it belongs to.
  """
  @spec normalize(list() | nil) :: {:ok, [map()]} | {:error, [{non_neg_integer(), problem()}]}
  def normalize(nil), do: {:ok, []}

  def normalize(rooms) when is_list(rooms) do
    rows =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        r = if is_map(r), do: r, else: %{}
        name = r |> text("name") |> String.trim()
        boards = BoardRanges.parse(text(r, "boards"))
        %{index: i, id: text(r, "id"), name: name, boards: boards}
      end)

    problems =
      Enum.flat_map(rows, &name_problems/1) ++
        duplicate_problems(rows) ++
        Enum.flat_map(rows, &boards_problems/1) ++
        overlap_problems(rows) ++
        if(length(rows) > @max_rooms, do: [{@max_rooms, :too_many}], else: [])

    if problems == [] do
      {:ok, Enum.map(rows, &stored(&1, rows))}
    else
      {:error, Enum.sort_by(problems, &elem(&1, 0))}
    end
  end

  def normalize(_other), do: {:error, [{0, :blank_name}]}

  defp name_problems(%{name: ""} = row), do: [{row.index, :blank_name}]

  defp name_problems(row) do
    if String.length(row.name) > @name_max, do: [{row.index, :name_too_long}], else: []
  end

  # The second of two rooms with one name is the one in the wrong.
  defp duplicate_problems(rows) do
    rows
    |> Enum.reject(&(&1.name == ""))
    |> Enum.group_by(&fold(&1.name))
    |> Enum.flat_map(fn {_name, [_first | rest]} ->
      Enum.map(rest, &{&1.index, :duplicate_name})
    end)
  end

  defp boards_problems(%{boards: {:error, reason}} = row), do: [{row.index, {:boards, reason}}]
  defp boards_problems(_row), do: []

  # A board in two rooms: the later room is told which earlier one has it.
  defp overlap_problems(rows) do
    readable = Enum.filter(rows, &match?({:ok, _}, &1.boards))

    for {later, n} <- Enum.with_index(readable),
        {:ok, b} = later.boards,
        earlier <- Enum.take(readable, n),
        {:ok, a} = earlier.boards,
        board = BoardRanges.first_shared(a, b),
        board != nil do
      {later.index, {:overlap, room_name(earlier), board}}
    end
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp room_name(%{name: "", index: i}), do: "##{i + 1}"
  defp room_name(%{name: name}), do: name

  defp stored(row, rows) do
    {:ok, ranges} = row.boards
    id = if row.id in ["", nil], do: new_id(rows), else: row.id
    %{"id" => id, "name" => row.name, "boards" => BoardRanges.format(ranges)}
  end

  defp new_id(rows) do
    id = :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
    if Enum.any?(rows, &(&1.id == id)), do: new_id(rows), else: id
  end

  defp text(map, key) do
    case Map.get(map, key, Map.get(map, String.to_existing_atom(key))) do
      v when is_binary(v) -> v
      v when is_integer(v) -> Integer.to_string(v)
      _ -> ""
    end
  end

  defp fold(name), do: name |> String.trim() |> String.downcase()

  @doc """
  One line of plain English for a problem, as a changeset error says it.
  The Rooms page words them itself, in the arbiter's language.
  """
  def problem_text(:blank_name), do: "a room needs a name"
  def problem_text(:name_too_long), do: "a room's name is at most #{@name_max} characters"
  def problem_text(:too_many), do: "a tournament has at most #{@max_rooms} rooms"
  def problem_text(:duplicate_name), do: "two rooms have the same name"

  def problem_text({:boards, {_reason, token}}),
    do: "#{inspect(token)} is not a board number or range"

  def problem_text({:overlap, other, board}),
    do: "board #{board} is already in #{other}"
end
