defmodule PairingsEngine.Federations.BEL.PlayerDataRefresh do
  @moduledoc """
  Bulk player-data refresh ("Update player data", formerly "Update clubs"):
  re-looks-up every registered player against the locally-synced KBSB list
  (`PairingsEngine.Federations.BEL.Members`, see `docs/kbsb-sync.md`) and
  the local FIDE list (`PairingsEngine.Fide`), and proposes every field that
  differs, without writing anything until `apply/2` is called.

  Deliberately the same shape as `PairingsEngine.RatingRefresh` - dry run,
  preview modal with a tick per change, apply - because it is the same
  gesture on different columns, and an arbiter who has used one should not
  have to learn the other. It is a SEPARATE action and it never proposes a
  rating: Elo, national rating and FIDE rating belong to "Refresh ratings",
  which answers a different question ("are these ratings current for this
  tournament's list?") at a different moment, and folding them in here
  would make an arbiter who only wanted clubs accept rating changes too.

  ## What it proposes, and from where

  From the matched KBSB row:

    * `name` - the list's "Last, First", whenever it differs from the
      player's once both are tidied the way the changeset tidies a name
      (whitespace runs, comma spacing). Case and accents count: correcting
      "JANSSENS, Bjorn" to "Janssens, Björn" is the point. The preview shows
      the old and new name side by side, so nobody gets renamed unseen.
    * `club` + `club_number` - the club name and the KBSB club id. These two
      share one tick in the preview and are applied together or not at all
      (each still appears only if it differs). A name that matches with a
      number that does not (or vice versa) is a club that was renamed or
      renumbered, and taking half of that is how a roster ends up with a
      name and a number that disagree.
    * `affiliated` - only where the row states it (`nil` on older uploads).
    * `fide_id` - only when the player has none, and only when no other player
      in the tournament already carries it (the changeset would refuse it,
      and one refusal rolls back the whole apply).
    * `national_id` - the same rule: filled when blank, never replaced.

  From the local FIDE list, through the player's FIDE id (or, for a player
  who has none yet, the FIDE id on their KBSB row):

    * `title` - the FIDE list is the only source of titles.

  And the three both lists know, `sex`, `birth_year` and `federation`:
  **the FIDE list first, the KBSB list when FIDE says nothing**. The rating
  report goes to FIDE and is checked against FIDE's own record, so a value
  that disagrees with FIDE's is the one that gets a report bounced; the
  national list is the better-than-nothing source for the many club players
  with no FIDE record. Federation is a special case of the same rule: the
  KBSB file's own `Fed` column is a wing letter (V/F/D), not a country, so
  the "KBSB" federation is `Members.fide_federation/1` - the FIDE list
  reached through the KBSB row's FIDE id - and it is only ever used when the
  player's own FIDE id found nothing.

  Club and affiliation come from KBSB alone: the FIDE list has neither.

  ## Birth date

  A player with a full `birth_date` keeps it whenever its year agrees with
  the list - a list that only knows the year has nothing to add to a date.
  Only `birth_year` is filled if it was blank. When the year DISAGREES, the
  proposal shows the date as the old value and, if ticked, sets the year and
  clears the date with it: keeping a date whose year contradicts the stored
  year is the inconsistency this exists to remove, and the preview says so.

  ## Matching, in three steps

  `player.national_id` first, then `player.fide_id`, then the player's
  name plus birth year.

  The two ids are exact and unique, and between them they cover everyone
  registered off either database. The name step exists for the case those
  two miss completely and which is very common at a club event: a player
  typed in by hand, with no matricule and no FIDE id. It is deliberately
  the last resort and deliberately timid - see `match_by_name/2`, which
  returns a row only when the name identifies exactly one person, and
  never guesses between namesakes.

  Matching by id at all is worth stating because the obvious alternative,
  the KBSB data platform's REST API, cannot do it: there is no by-FIDE-id
  club route, and its FIDE table carries no club or membership. Going
  through the already-synced local copies covers strictly more players,
  needs no API key, and works offline in a playing hall - which is where
  this button gets pressed.

  ## What it will not do

  It never proposes CLEARING a value. A KBSB row with a blank club is a
  player whose membership lapsed or was never recorded, a FIDE row with no
  title is a list that does not mention one, and the arbiter who typed
  either into the registration dialog knows something the sync does not.
  Propose what the source asserts; never propose deleting what it merely
  fails to mention. (The birth-date case above is not an exception: the
  source asserts a different year.)
  """

  alias PairingsEngine.Fide
  alias PairingsEngine.Federations.BEL.Members
  alias PairingsEngine.Federations.BEL.Member
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Player

  @derive {Inspect, only: [:field, :old, :new, :via, :source, :id]}
  defstruct [:player, :field, :old, :new, :via, :source, :id, extra: %{}]

  @type via :: :national_id | :fide_id | :name
  @type source :: :kbsb | :fide

  @type t :: %__MODULE__{
          player: Player.t(),
          field: atom(),
          old: term(),
          new: term(),
          via: via(),
          source: source(),
          id: String.t(),
          extra: map()
        }

  @type summary :: %{
          proposals: [t()],
          checked: non_neg_integer(),
          changed: non_neg_integer(),
          unmatched: non_neg_integer()
        }

  @doc """
  Looks up every player in `tournament` against the local KBSB and FIDE
  copies and returns `%{proposals:, checked:, changed:, unmatched:}` -
  `changed` is the number of players with at least one proposed change,
  `unmatched` the number found on neither list. Writes nothing; pair with
  `apply/2` to commit.
  """
  @spec dry_run(Tournaments.Tournament.t()) :: summary()
  def dry_run(tournament) do
    index = Members.name_index()
    players = Tournaments.list_players(tournament.id)
    fide_ids_in_use = players |> Enum.map(& &1.fide_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

    results = Enum.map(players, &player_proposals(&1, index, fide_ids_in_use))

    %{
      proposals: Enum.flat_map(results, & &1.proposals),
      checked: length(results),
      changed: Enum.count(results, &(&1.proposals != [])),
      unmatched: Enum.count(results, &(not &1.matched?))
    }
  end

  defp player_proposals(player, index, fide_ids_in_use) do
    {row, via} = kbsb_match(player, index) || {nil, nil}
    fide = fide_record(player, row)
    fide_via = if player.fide_id, do: :fide_id, else: via

    kbsb = fn field, old, new -> {field, old, new, :kbsb, via} end
    from_fide = fn field, old, new -> {field, old, new, :fide, fide_via} end

    candidates =
      [
        row && kbsb.(:name, player.name, kbsb_name(row)),
        row && kbsb.(:club, player.club, club_name(row)),
        row && kbsb.(:club_number, player.club_number, row.club_number),
        sex_candidate(player, fide, row, from_fide, kbsb),
        birth_year_candidate(player, fide, row, from_fide, kbsb),
        federation_candidate(player, fide, row, from_fide, kbsb),
        fide && from_fide.(:title, player.title, present(fide.title)),
        row && kbsb.(:affiliated, player.affiliated, row.affiliated),
        row && kbsb.(:fide_id, player.fide_id, new_fide_id(player, row, fide_ids_in_use)),
        row && kbsb.(:national_id, player.national_id, new_national_id(player, row))
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    proposals = Enum.flat_map(candidates, &build(player, &1))

    %{proposals: proposals, matched?: row != nil or fide != nil}
  end

  # The FIDE record for this player: by their own FIDE id, or - for a player
  # with none yet - by the one their KBSB row carries, which is also what the
  # `fide_id` proposal would fill in. One person, one record, either way.
  defp fide_record(%Player{fide_id: id}, _row) when is_integer(id), do: Fide.get_player(id)
  defp fide_record(_player, %Member{fide_id: id}) when is_integer(id), do: Fide.get_player(id)
  defp fide_record(_player, _row), do: nil

  # FIDE first, KBSB when FIDE is silent - see the moduledoc for why.
  defp sex_candidate(player, fide, row, from_fide, kbsb) do
    fide_sex = fide && present(Player.normalize_sex(fide.sex))
    kbsb_sex = row && row.sex

    cond do
      fide_sex -> from_fide.(:sex, player.sex, fide_sex)
      kbsb_sex -> kbsb.(:sex, player.sex, kbsb_sex)
      true -> nil
    end
  end

  defp birth_year_candidate(player, fide, row, from_fide, kbsb) do
    fide_year = fide && year(fide.birth_year)
    kbsb_year = row && year(row.birth_year)

    cond do
      fide_year -> from_fide.(:birth_year, player.birth_year, fide_year)
      kbsb_year -> kbsb.(:birth_year, player.birth_year, kbsb_year)
      true -> nil
    end
  end

  defp federation_candidate(player, fide, row, from_fide, kbsb) do
    # The KBSB side is itself a FIDE-list lookup (see the moduledoc), so it
    # is only made when the player's own record had nothing to say.
    case fide && country(fide.federation) do
      nil ->
        case row && Members.fide_federation(row) do
          nil -> nil
          kbsb_fed -> kbsb.(:federation, player.federation, kbsb_fed)
        end

      fide_fed ->
        from_fide.(:federation, player.federation, fide_fed)
    end
  end

  # One candidate into zero or one proposal. `new == nil` is the source
  # saying nothing, which is never a reason to propose anything.
  defp build(_player, {_field, _old, nil, _source, _via}), do: []

  defp build(player, {:birth_year, old, new, source, via}) do
    case player.birth_date do
      # The date's year agrees: the date stays, and the year is filled only
      # if it was missing.
      %Date{year: ^new} ->
        if old == new, do: [], else: [proposal(player, :birth_year, old, new, source, via)]

      # It disagrees: the year changes and the contradicting date goes with
      # it, shown as the old value so the arbiter can see what is dropped.
      %Date{} = date ->
        [proposal(player, :birth_year, date, new, source, via, %{birth_date: nil})]

      nil ->
        if old == new, do: [], else: [proposal(player, :birth_year, old, new, source, via)]
    end
  end

  defp build(player, {field, old, new, source, via}) do
    if same?(field, old, new), do: [], else: [proposal(player, field, old, new, source, via)]
  end

  defp proposal(player, field, old, new, source, via, extra \\ %{}) do
    %__MODULE__{
      player: player,
      field: field,
      old: old,
      new: new,
      via: via,
      source: source,
      id: proposal_id(player, field),
      extra: extra
    }
  end

  # Club name and number share an id, so the preview's one tick selects both.
  defp proposal_id(player, field) when field in [:club, :club_number], do: "#{player.id}:club"
  defp proposal_id(player, field), do: "#{player.id}:#{field}"

  defp same?(:name, old, new), do: tidy_name(old) == tidy_name(new)
  defp same?(:sex, old, new), do: Player.normalize_sex(old) == new
  defp same?(:title, old, new), do: trim(old) == trim(new)

  defp same?(:federation, old, new),
    do: old |> trim() |> String.upcase() == String.upcase(new)

  defp same?(_field, old, new), do: old == new

  # What `Player.changeset/2` does to a name on save, plus collapsing inner
  # whitespace: differences the arbiter could not see in the table are not
  # worth a row in the preview.
  defp tidy_name(name) do
    name
    |> trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(~r/\s*,\s*/u, ", ")
  end

  defp kbsb_name(%Member{last_name: last} = row) when is_binary(last) and last != "" do
    Member.full_name(row)
  end

  defp kbsb_name(_row), do: nil

  defp club_name(%Member{club_name: name}) when name in [nil, ""], do: nil
  defp club_name(%Member{club_name: name}), do: name

  # Filled in, never replaced - an id is how the next lookup finds the
  # player, and swapping one for another is not a refresh.
  defp new_fide_id(%Player{fide_id: nil}, %Member{fide_id: id}, in_use) when is_integer(id) do
    if MapSet.member?(in_use, id), do: nil, else: id
  end

  defp new_fide_id(_player, _row, _in_use), do: nil

  defp new_national_id(%Player{national_id: current}, %Member{national_id: id})
       when is_binary(id) and id != "" do
    if trim(current) == "", do: id, else: nil
  end

  defp new_national_id(_player, _row), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp present(_value), do: nil

  defp year(y) when is_integer(y) and y > 0, do: y
  defp year(_y), do: nil

  defp country(value) when is_binary(value) do
    value = String.trim(value)
    if String.length(value) == 3, do: String.upcase(value), else: nil
  end

  defp country(_value), do: nil

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: to_string(value)

  # National id first - it is the KBSB's own primary key, so it cannot be
  # ambiguous. FIDE id second, and only as a fallback: it is indexed but not
  # unique on the local copy, so `find_by_fide_id/1` takes the first row.
  # That is the right trade for a preview-then-apply action (the arbiter
  # sees the proposed change before it is written) and the wrong one for a
  # silent background write, which is why this stays behind a button.
  defp kbsb_match(%Player{} = player, index) do
    cond do
      row = Members.find_by_national_id(player.national_id) -> {row, :national_id}
      row = Members.find_by_fide_id(player.fide_id) -> {row, :fide_id}
      row = match_by_name(player, index) -> {row, :name}
      true -> nil
    end
  end

  # Last resort, for the common case this feature would otherwise miss
  # entirely: a player typed in by hand at the desk, with no matricule and
  # no FIDE id. Both ids are exact and unique; a name is neither, so this
  # only ever returns a row it can be SURE of.
  #
  #   * exactly one row with that name -> that row, unless the player and
  #     the row both carry a birth year and the years disagree (a different
  #     person who happens to share the name)
  #   * several rows with that name -> only if the birth year singles out
  #     exactly one of them; otherwise no match at all
  #
  # It never picks "the first" or "the highest rated". A wrong club written
  # onto a player is worse than no club, and an arbiter reviewing a long
  # preview will not catch a plausible-looking wrong one.
  defp match_by_name(%Player{name: name, birth_year: year}, index) do
    case Map.get(index, Members.normalize_name(name), []) do
      [] -> nil
      [only] -> if year_agrees?(only, year), do: only, else: nil
      many -> only_one_born_in(many, year)
    end
  end

  defp only_one_born_in(_rows, nil), do: nil

  defp only_one_born_in(rows, year) do
    case Enum.filter(rows, &(&1.birth_year == year)) do
      [only] -> only
      _ -> nil
    end
  end

  defp year_agrees?(_row, nil), do: true
  defp year_agrees?(%Member{birth_year: nil}, _year), do: true
  defp year_agrees?(%Member{birth_year: listed}, year), do: listed == year

  @doc """
  The proposals of `summary` whose `id` is in `ids`, in their original
  order. Club name and number share an id, so they are chosen together.
  """
  def select(%{proposals: proposals}, ids) do
    wanted = MapSet.new(ids)
    Enum.filter(proposals, &MapSet.member?(wanted, &1.id))
  end

  @doc """
  Applies `proposals` (a `dry_run/1` summary's `:proposals`, or any subset
  `select/2` chose) to `tournament` in a single transaction, firing exactly
  one `tournament_changed` broadcast (via
  `PairingsEngine.Tournaments.bulk_update_players/2`). Proposals for the
  same player are grouped into a single update; a proposal's `extra` (the
  cleared birth date) travels with it.

  `RatingRefresh.apply/2` is nearly this function, and is not called: that
  would be an undeclared cross-module contract holding two features together
  by accident, and the dozen lines are cheaper than the day someone spends
  finding out.
  """
  @spec apply(Tournaments.Tournament.t(), [t()]) :: {:ok, [Player.t()]} | {:error, term()}
  def apply(tournament, proposals) do
    updates =
      proposals
      |> Enum.group_by(& &1.player.id)
      |> Enum.map(fn {_player_id, props} ->
        player = hd(props).player

        attrs =
          Enum.reduce(props, %{}, fn p, acc ->
            acc |> Map.put(p.field, p.new) |> Map.merge(p.extra)
          end)

        {player, attrs}
      end)

    Tournaments.bulk_update_players(tournament.id, updates)
  end
end
