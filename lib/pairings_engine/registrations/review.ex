defmodule PairingsEngine.Registrations.Review do
  @moduledoc """
  What an entry from the results site becomes when it is accepted, and what
  it might be a duplicate of - the two things an arbiter reads before
  pressing a button.

  ## The player an entry would become

  `proposal/3` starts from what the person typed and fills in from the two
  lists this machine already holds, the same way the Players page's own add
  form does when an arbiter picks a name off the FIDE list or types a KBSB
  number:

    * **the national list** (KBSB/FRBE), when the entry carries a national
      ID - or a FIDE ID the list cross-references - and the arbiter has the
      Belgian lookup switched on: national ID, national rating, club and
      club number, and anything the entrant left blank;
    * **the FIDE list**, when the entry carries a FIDE ID it knows (or the
      national list supplied one): the rating for this tournament's own
      tempo, title, federation, sex and birth year. The list wins on those:
      a rating typed into a public form is a claim, the list is the list.

  The name is the one field the list does NOT simply overwrite. When the
  typed name and the list's name for that FIDE ID are the same person
  spelled differently ("carlsen magnus" / "Carlsen, Magnus") the list's
  spelling is used; when they are different people, the typed name is kept
  and a note says so - that is either a typo in the FIDE ID or somebody
  entering under another player's number, and it is the arbiter's call.

  Nothing here writes. `PairingsEngine.Registrations.accept/2` creates the
  player from `proposal/3`'s attrs; the review screen shows the same attrs
  and notes before anybody presses Accept, so what is shown is what is
  created.

  ## Duplicates

  `duplicates/3` answers "have I seen this person already?" against the
  tournament's players and the other entries waiting. Same FIDE ID or same
  national ID is a duplicate for certain; same name (ignoring order, case,
  accents and punctuation) is a probable one, as is the same email on
  another waiting entry - a person who sent the form twice. Only the FIDE ID
  against an existing player blocks accepting (`Tournaments.create_player/2`
  refuses it); everything else is information.
  """

  alias PairingsEngine.Fide
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Federations.BEL.{Member, Members}
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @type note ::
          {:fide_list, String.t()}
          | {:fide_not_listed, integer()}
          | {:fide_name_differs, String.t()}
          | {:rating_from_list, integer(), integer()}
          | {:national_list, String.t()}
          | {:national_not_listed, String.t()}

  @doc """
  The attrs `Tournaments.create_player/2` would get, and notes on where they
  came from.

  `opts`:

    * `:national_list` - consult the KBSB/FRBE list (default `false`; the
      caller passes the arbiter's `bel_player_lookup` switch, the same one
      that governs the Players page's own KBSB autofill).
  """
  @spec proposal(Registration.t(), Tournament.t(), keyword()) :: %{
          attrs: map(),
          notes: [note()]
        }
  def proposal(%Registration{} = registration, %Tournament{} = tournament, opts \\ []) do
    typed = typed_attrs(registration, tournament)

    {attrs, notes} =
      if Keyword.get(opts, :national_list, false),
        do: national(typed, []),
        else: {typed, []}

    {attrs, notes} = fide(attrs, notes, tournament)

    %{attrs: attrs, notes: Enum.reverse(notes)}
  end

  # What the entry itself says, before either list is consulted. A
  # hand-written allowlist, never the payload's player object as it stands:
  # the email is the one field in this feature that must not travel onward,
  # and an allowlist makes "not published" the default for anything the
  # public form adds later. `PairingsEngine.Snapshot`'s `player_row/1` is the
  # same decision at the other end of the system.
  defp typed_attrs(%Registration{} = registration, %Tournament{} = tournament) do
    player = Registration.player_data(registration)

    %{
      "name" => trimmed(player["name"]),
      "title" => trimmed(player["title"]),
      "fide_id" => whole_number(player["fide_id"]),
      # The contract has one `rating`; this app has `fide_rating` and
      # `national_rating`. It goes to `fide_rating` because it arrives beside
      # `fide_id`, `federation` and `title` in a FIDE-shaped object, and
      # because `Player.rating/1` falls back to the national field rather
      # than the other way round. The FIDE list replaces it below when the
      # player is on it.
      "fide_rating" => whole_number(player["rating"]),
      "federation" => trimmed(player["federation"]),
      "club" => trimmed(player["club"]),
      "birth_year" => whole_number(player["birth_year"]),
      # A string: a KBSB "G licence" is a negative number that names a
      # different person from the positive one, so it is an identifier and
      # never arithmetic.
      "national_id" => national_id(player["national_id"]),
      "absent_rounds" => requested_byes(player["requested_byes"], tournament),
      # A web form is an intention, not an arrival - see
      # `PairingsEngine.Registrations`.
      "absent" => true
    }
    |> drop_nils()
  end

  ## ---------- the national list ----------

  defp national(attrs, notes) do
    member =
      case attrs["national_id"] do
        # A number the person typed is looked up as typed and nothing else:
        # finding a member through the FIDE ID instead would quietly swap
        # their number for another one.
        nil -> Members.find_by_fide_id(attrs["fide_id"])
        typed -> Members.find_by_national_id(typed)
      end

    case member do
      %Member{} = member ->
        attrs =
          attrs
          |> Map.put("national_id", member.national_id)
          |> put_present("national_rating", member.national_rating)
          |> put_present("club", blank_to_nil(member.club_name))
          |> put_present("club_number", member.club_number)
          |> put_if_blank("federation", blank_to_nil(member.federation))
          |> put_if_blank("birth_year", member.birth_year)
          |> put_if_blank("fide_id", member.fide_id)
          |> put_if_blank("name", Member.full_name(member))

        {attrs, [{:national_list, member.national_id} | notes]}

      nil ->
        case attrs["national_id"] do
          nil -> {attrs, notes}
          id -> {attrs, [{:national_not_listed, id} | notes]}
        end
    end
  end

  ## ---------- the FIDE list ----------

  defp fide(%{"fide_id" => fide_id} = attrs, notes, tournament) when is_integer(fide_id) do
    case Fide.get_player(fide_id) do
      %FidePlayer{} = fp ->
        {attrs, notes} = fide_rating(attrs, notes, Fide.rating_for_tempo(fp, tournament.standard))

        {name, notes} = fide_name(attrs["name"], fp.name, notes)

        attrs =
          attrs
          |> Map.put("name", name)
          |> put_present("title", blank_to_nil(fp.title))
          |> put_present("federation", blank_to_nil(fp.federation))
          |> put_present("birth_year", fp.birth_year)
          |> put_present("sex", sex(fp.sex))

        {attrs, [{:fide_list, fp.name} | notes]}

      nil ->
        {attrs, [{:fide_not_listed, fide_id} | notes]}
    end
  end

  defp fide(attrs, notes, _tournament), do: {attrs, notes}

  defp fide_rating(attrs, notes, list) when is_integer(list) and list > 0 do
    notes =
      case attrs["fide_rating"] do
        typed when is_integer(typed) and typed != list ->
          [{:rating_from_list, list, typed} | notes]

        _same_or_none ->
          notes
      end

    {Map.put(attrs, "fide_rating", list), notes}
  end

  defp fide_rating(attrs, notes, _unrated), do: {attrs, notes}

  defp fide_name(nil, list_name, notes), do: {list_name, notes}

  defp fide_name(typed, list_name, notes) do
    if same_name?(typed, list_name),
      do: {list_name, notes},
      else: {typed, [{:fide_name_differs, list_name} | notes]}
  end

  ## ---------- duplicates ----------

  @doc """
  What `registration` might duplicate, among `players` and the other
  waiting `entries`. Each hit is `%{kind: :player | :entry, id:, name:,
  reason: :fide_id | :national_id | :name | :email}`, strongest reason first
  and one hit per person.
  """
  @spec duplicates(Registration.t(), [Player.t()], [Registration.t()]) :: [map()]
  def duplicates(%Registration{} = registration, players, entries) do
    mine = identity(Registration.player_data(registration))

    player_hits =
      for %Player{} = player <- players,
          reason = match_reason(mine, player_identity(player)),
          do: %{kind: :player, id: player.id, name: player.name, reason: reason}

    entry_hits =
      for %Registration{} = other <- entries,
          other.id != registration.id,
          reason = match_reason(mine, identity(Registration.player_data(other))),
          do: %{kind: :entry, id: other.id, name: Registration.name(other), reason: reason}

    player_hits ++ entry_hits
  end

  # The first reason that holds, strongest first. `nil` never matches: two
  # entries without a FIDE ID are not the same person for lacking one.
  defp match_reason(a, b) do
    cond do
      a.fide_id && a.fide_id == b.fide_id -> :fide_id
      a.national_id && a.national_id == b.national_id -> :national_id
      a.name && a.name == b.name -> :name
      a.email && a.email == b.email -> :email
      true -> nil
    end
  end

  defp identity(player) when is_map(player) do
    %{
      fide_id: whole_number(player["fide_id"]),
      national_id: national_id(player["national_id"]),
      name: name_key(player["name"]),
      email: email_key(player["email"])
    }
  end

  defp player_identity(%Player{} = player) do
    %{
      fide_id: player.fide_id,
      national_id: national_id(player.national_id),
      name: name_key(player.name),
      email: nil
    }
  end

  @doc """
  Whether two spellings name the same person: case, accents, punctuation
  and word order ignored, so "De Vos, Ilse" and "ilse de vos" agree.
  """
  @spec same_name?(String.t() | nil, String.t() | nil) :: boolean()
  def same_name?(a, b) do
    key = name_key(a)
    key != nil and key == name_key(b)
  end

  defp name_key(name) when is_binary(name) do
    case name |> Members.normalize_name() |> String.split(" ", trim: true) do
      [] -> nil
      words -> words |> Enum.sort() |> Enum.join(" ")
    end
  end

  defp name_key(_absent), do: nil

  defp email_key(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      key -> key
    end
  end

  defp email_key(_absent), do: nil

  ## ---------- odds and ends ----------

  # Every value is re-derived from the round count rather than trusted:
  # "1-999" is a perfectly well-formed request from a form with no login
  # behind it. See `PairingsEngine.Registrations` for why a requested bye is
  # `absent_rounds` and nothing else.
  defp requested_byes(rounds, %Tournament{} = tournament) when is_list(rounds) do
    last = tournament.rounds_count || 0

    rounds
    |> Enum.map(&round_number/1)
    |> Enum.filter(&(is_integer(&1) and &1 >= 1 and &1 <= last))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp requested_byes(_absent_or_wrong_shape, _tournament), do: ""

  @doc false
  def round_number(value) when is_integer(value), do: value

  def round_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  def round_number(_value), do: nil

  defp national_id(value) when is_integer(value), do: Integer.to_string(value)
  defp national_id(value) when is_binary(value), do: trimmed(value)
  defp national_id(_value), do: nil

  defp sex(value) when is_binary(value) do
    case String.downcase(value) do
      "f" -> "w"
      "w" -> "w"
      "m" -> "m"
      _unknown -> nil
    end
  end

  defp sex(_value), do: nil

  # Rating, FIDE ID and birth year land in `:integer` columns, and Ecto's
  # cast refuses a float or a numeric string outright. The contract says
  # these are numbers and they normally are - but the sender is a web form,
  # and a form that posts `"1804"` or `1804.0` would otherwise produce an
  # entry the arbiter cannot accept at all.
  defp whole_number(value) when is_integer(value), do: value
  defp whole_number(value) when is_float(value), do: trunc(value)

  defp whole_number(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, ""} -> number
      _not_a_whole_number -> nil
    end
  end

  defp whole_number(_value), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_not_a_string), do: nil

  defp blank_to_nil(value) when is_binary(value), do: trimmed(value)
  defp blank_to_nil(value), do: value

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp put_if_blank(attrs, _key, nil), do: attrs

  defp put_if_blank(attrs, key, value) do
    case Map.get(attrs, key) do
      nil -> Map.put(attrs, key, value)
      _already -> attrs
    end
  end

  defp drop_nils(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
