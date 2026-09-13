defmodule PairingsEngine.Federations.BEL.Clubs do
  @moduledoc """
  Club number -> club name, for the one thing the public players.sqlite
  never carries: a name for the `Club` number on each row.

  ## Two optional sources, plus a durable fallback

  Precedence, decided fresh on every sync (`resolve/2`):

    1. A `clubs` table bundled inside that month's `players.sqlite` zip, if
       the maintainer chose to publish one. Detected automatically - no
       setting. Recognised columns: the number as `Club`, `IdClub` or
       `ClubNumber`; the name as `Name` or `ClubName` (case-insensitive).
    2. The "Belgian club names URL" setting, if one is configured - a
       second file, fetched the same way as the players list (conditional
       GET, size cap, timeout). Either CSV with a `number,name` header, or
       JSON as either `[{"number": 417, "name": "..."}]` or
       `{"417": "..."}`.
    3. Whatever this table already has on file from a previous sync.

  A club with no name known from ANY of the three is shown by its number
  in the UI rather than hidden or guessed at - see
  `PairingsEngine.Federations.BEL.Member.club_label/1`.

  ## Why a separate table survives the full player-roster replace

  `kbsb_players` is fully replaced on every sync (see
  `PairingsEngine.Federations.BEL.Sync`), because the players list is
  authoritative for exactly what it lists. A club name is not something
  that list asserts at all - it can be missing from one month's zip and
  present the next, or the clubs URL can go offline for a while - so a
  name learned once is kept here and only ever overwritten by a fresher
  name for the SAME number, never erased for the mere absence of a source
  that used to supply it.
  """

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Federations.BEL.Club

  @doc """
  Merges `zip_clubs` and `url_clubs` (each `%{club_number => name}`, or
  `nil`/`%{}` if that source produced nothing this run) into the durable
  `kbsb_clubs` table - a name from the zip wins over one from the URL for
  the same number, and either wins over what was already stored - then
  returns the FULL resulting map (every club number ever seen, not only
  the ones just merged), ready to look club names up in while importing
  players.
  """
  @spec resolve(map() | nil, map() | nil) :: %{integer() => String.t()}
  def resolve(zip_clubs, url_clubs) do
    zip_clubs = zip_clubs || %{}
    url_clubs = url_clubs || %{}

    # URL clubs first, then zip clubs written on top - zip wins on overlap.
    merged = Map.merge(url_clubs, zip_clubs)

    if map_size(merged) > 0 do
      upsert(merged)
    end

    all()
  end

  defp upsert(map) do
    rows =
      for {number, name} <- map, is_integer(number), is_binary(name), name != "" do
        %{club_number: number, name: name}
      end

    if rows != [] do
      Repo.insert_all(Club, rows, on_conflict: :replace_all, conflict_target: :club_number)
    end
  end

  @doc "Every known club number -> name, as `%{club_number => name}`."
  def all do
    Club
    |> Repo.all()
    |> Map.new(&{&1.club_number, &1.name})
  end

  @doc "The name known for `club_number`, or `nil`."
  def name_for(nil), do: nil

  def name_for(club_number) when is_integer(club_number) do
    Repo.one(from c in Club, where: c.club_number == ^club_number, select: c.name)
  end
end
