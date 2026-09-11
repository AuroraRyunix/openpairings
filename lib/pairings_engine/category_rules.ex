defmodule PairingsEngine.CategoryRules do
  @moduledoc """
  The condition language behind a tournament's `category_rules` (see
  `PairingsEngine.Tournaments.Tournament`'s field doc for the stored shape),
  and the FIDE age arithmetic it is evaluated against.

  ## Better than SWAR, deliberately

  SWAR gives a player exactly one category, from one rule, on one axis
  (rating OR age), as non-overlapping bands. That is a real limitation: a
  club running "U1800 AND U1600" as two separate prizes, or "rating below
  1800 AND age 45+" as one combined prize, cannot be expressed as a single
  SWAR-style threshold.

  Here a category's rule is a SET of independent conditions - any
  combination of `"rating_from"` (>=), `"rating_below"` (<), `"age_from"`
  (>=), `"age_below"` (<) and `"women"` (true/absent) - and a player
  qualifies for a category when EVERY condition the arbiter set is true for
  them. A category with none of the five keys set (`nil`, or a map with none
  of them) is not rule-owned at all - it stays a plain name the arbiter
  assigns by hand on the Players page, exactly as a ruleless category always
  has. `rule_owned?/1` is the single test for that distinction; every reader
  of `category_rules` (auto-assign, the editor, the legacy migration) goes
  through it rather than re-deriving "has a rule" from the map's shape.

  Unlike SWAR's implicit non-overlapping bands, two rule-owned categories
  here are free to overlap - "U1800" and "U1600" both matching a 1500-rated
  player is the point, not a bug to collapse away. Nothing here picks a
  single winner among several matching categories; that collapse only ever
  happened for `players.category`, the single-valued pairing-pool override,
  and it is `PairingsEngine.Categories.pairing_category/2`'s job, not this
  module's.

  ## Age: FIDE's 1 January convention

  A player's age for a category is their age on 1 January of the
  tournament's year (`tournament_year/1`) - not "years since birth" (the
  legacy arithmetic this module's `migrate_legacy_rules/2` translates away
  from, and still SWAR's own convention). From a birth YEAR alone that is
  `year - birth_year - 1`: on 1 January nobody has had this year's birthday
  yet, unless they were born on 1 January itself, which is why
  `age_at_year_start/2` prefers an exact birth date when the player has one
  rather than applying the `-1` unconditionally.

  ## Unrated players

  A rating of `0` (`PairingsEngine.Tournaments.Player.rating/1`'s "no rating
  on file" value) satisfies `rating_below` (0 is under any positive
  ceiling) and never satisfies `rating_from` (0 is not `>=` any positive
  floor) - the same reading `PairingsEngine.PlayerStats` has always given an
  unrated player, needing no special-case here: both comparisons are simply
  arithmetic against 0.
  """

  alias PairingsEngine.Tournaments.Player

  @condition_keys ~w(rating_from rating_below age_from age_below women)

  @doc "The recognised condition keys a `category_rules` entry may carry."
  def condition_keys, do: @condition_keys

  @doc """
  True when `rule` sets at least one condition - i.e. this category is
  RULE-OWNED (auto-assignable) rather than a plain hand-assigned name.

  `nil`, `%{}`, and a map holding only unrecognised keys all mean "no
  rule" - the same reading `category_rules` has always given a category
  with no entry at all, now extended to an entry that is present but empty.
  """
  @spec rule_owned?(map() | nil) :: boolean()
  def rule_owned?(rule) when is_map(rule), do: Enum.any?(@condition_keys, &Map.has_key?(rule, &1))
  def rule_owned?(_rule), do: false

  @doc """
  Does `player` (rated `rating`, aged `age` - both precomputed by the
  caller, since both are the same per-player facts every category's rule is
  checked against) satisfy every condition `rule` sets?

  A category with no rule never matches here - see `rule_owned?/1`. `age`
  is `nil` for a player with neither a birth date nor a birth year on file;
  both age conditions fail for such a player rather than raising, the same
  "missing data means no match" reading the legacy rules always gave an
  age rule.
  """
  @spec matches?(map() | nil, Player.t(), integer(), integer() | nil) :: boolean()
  def matches?(rule, %Player{} = player, rating, age) do
    rule_owned?(rule) and
      condition_ok?(rule, "rating_from", &(rating >= &1)) and
      condition_ok?(rule, "rating_below", &(rating < &1)) and
      condition_ok?(rule, "age_from", &(age != nil and age >= &1)) and
      condition_ok?(rule, "age_below", &(age != nil and age < &1)) and
      women_ok?(rule, player)
  end

  defp condition_ok?(rule, key, test) do
    case Map.get(rule, key) do
      nil -> true
      value -> test.(value)
    end
  end

  # Stored internally as "m"/"w" - see `Player.sex_label/1`. A category with
  # no "women" key (or `women: false`, which the editor never writes but a
  # hand-edited backup could) is not restricted by sex at all.
  defp women_ok?(%{"women" => true}, %Player{sex: "w"}), do: true
  defp women_ok?(%{"women" => true}, %Player{}), do: false
  defp women_ok?(_rule, %Player{}), do: true

  @doc """
  The calendar year a category's age conditions are evaluated against for
  `tournament`: the year of round 1's date (`round_dates`'s first entry),
  else the tournament's own `start_date`, else today.

  Round 1's date is asked for specifically, not "the earliest round date" -
  in the ordinary case they are the same date, but a tournament is not
  guaranteed to have entered its dates in round order. `start_date` is
  itself derived from `round_dates` (see `Tournament.changeset/2`'s
  `derive_dates_from_round_dates/1`) so it is usually redundant with the
  first fallback, but it is not always: a tournament whose round 1 date is
  blank while a later round's is set still has a `start_date` to fall back
  to before reaching for today.
  """
  @spec tournament_year(map()) :: integer()
  def tournament_year(tournament) do
    cond do
      year = year_from_date(List.first(tournament.round_dates || [])) -> year
      year = year_from_date(Map.get(tournament, :start_date)) -> year
      true -> Date.utc_today().year
    end
  end

  defp year_from_date(date) when is_binary(date) and date != "" do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed.year
      {:error, _} -> nil
    end
  end

  defp year_from_date(_date), do: nil

  @doc """
  `player`'s age on 1 January of `year` - the FIDE convention every age
  condition is checked against (see the moduledoc).

  Prefers an exact `birth_date` when the player has one: on 1 January
  nobody has had this year's birthday yet UNLESS they were born on 1
  January itself, so the plain "`year - birth_year`" arithmetic is off by
  one for everybody except that one calendar date. Falls back to
  `year - birth_year - 1` (that same `-1` applied unconditionally) when
  only the birth year is on file. Returns `nil` when neither is - matching
  the legacy age rules' own "no birth data means no match", now made
  explicit rather than folding into a `false` a caller could mistake for a
  real comparison.
  """
  @spec age_at_year_start(Player.t(), integer()) :: integer() | nil
  def age_at_year_start(%Player{birth_date: %Date{} = birth_date}, year) do
    reference = {1, 1}
    age = year - birth_date.year
    if reference >= {birth_date.month, birth_date.day}, do: age, else: age - 1
  end

  def age_at_year_start(%Player{birth_year: birth_year}, year) when is_integer(birth_year),
    do: year - birth_year - 1

  def age_at_year_start(%Player{}, _year), do: nil

  @doc """
  The birth-year hint for an `age_below` threshold, shown live next to the
  editor's input: a player qualifies (age at 1 January `year` is under
  `age_below_value`) when born in `birth_year_on_or_after/2` or later.

      iex> PairingsEngine.CategoryRules.birth_year_on_or_after(2026, 16)
      2010
  """
  @spec birth_year_on_or_after(integer(), integer()) :: integer()
  def birth_year_on_or_after(year, age_below_value), do: year - age_below_value

  @doc """
  The birth-year hint for an `age_from` threshold: a player qualifies (age
  at 1 January `year` is `age_from_value` or over) when born in
  `birth_year_on_or_before/2` or earlier.

      iex> PairingsEngine.CategoryRules.birth_year_on_or_before(2026, 45)
      1980
  """
  @spec birth_year_on_or_before(integer(), integer()) :: integer()
  def birth_year_on_or_before(year, age_from_value), do: year - age_from_value - 1

  # ---------- Legacy conversion ----------
  #
  # The ONE place the old `%{"kind" => "elo_below" | "elo_above" |
  # "age_below" | "age_above", "value" => n}` shape becomes the new one -
  # used by the `MigrateLegacyCategoryRules` data migration (existing
  # tournaments) and by `PairingsEngine.TournamentImport` (a backup file
  # carrying the old shape). Both callers pass the SAME `category_rules` map
  # and `category_order` (the tournament's own `categories` list) a
  # tournament always has both of, so there is exactly one code path that
  # can drift from `PlayerStats.assign_categories/4`'s old behaviour.

  @legacy_kinds ~w(elo_below elo_above age_below age_above)

  # Per legacy kind: how its integer `value` becomes the new scale, which
  # new key it becomes the PRIMARY condition on, and which new key a
  # LOOSER category of the same kind needs as its excluding cap (see
  # `band_group/3`'s doc below for what "cap" means).
  #
  #   elo_below v   ->  rating < v            (no shift: "<" stays "<")
  #   elo_above v   ->  rating >= v + 1        (">" becomes ">=" over
  #                                             integers)
  #   age_below v   ->  new_age < v - 1        (legacy_age = new_age + 1,
  #                                             so legacy_age < v
  #                                             <=> new_age < v - 1)
  #   age_above v   ->  new_age >= v            (legacy_age > v
  #                                             <=> new_age + 1 > v
  #                                             <=> new_age >= v, over
  #                                             integers)
  defp kind_spec("elo_below"),
    do: %{
      to_new: &Function.identity/1,
      primary: "rating_below",
      cap: "rating_from",
      tighter: :min
    }

  defp kind_spec("elo_above"),
    do: %{to_new: &(&1 + 1), primary: "rating_from", cap: "rating_below", tighter: :max}

  defp kind_spec("age_below"),
    do: %{to_new: &(&1 - 1), primary: "age_below", cap: "age_from", tighter: :min}

  defp kind_spec("age_above"),
    do: %{to_new: &Function.identity/1, primary: "age_from", cap: "age_below", tighter: :max}

  @doc """
  Converts one tournament's `category_rules` from the legacy
  `"kind"`/`"value"` shape to the new condition-set shape, preserving
  exactly what `PairingsEngine.PlayerStats.assign_categories/4` used to
  decide for every player (given the same year both the old default and the
  new `tournament_year/1` would resolve to - see that function's own doc
  for the one case that can differ: a tournament whose derived year is not
  the real calendar year the conversion runs in).

  A category whose rule is not in the legacy shape (already new-shape,
  `nil`, or missing) passes through unchanged - this function is safe to
  run over a `category_rules` map that is a MIX of legacy and already-new
  entries, which a hand-edited or partially-migrated backup file could be.

  ## The tightest-per-kind collapse, as bands

  The legacy rules picked only the TIGHTEST match per literal `kind` for
  each player (`PlayerStats.assign_categories/4`'s old `min_by` over
  `tightness_key/1`) - a 1000-rated player in a tournament with both
  `elo_below 1100` and `elo_below 1200` landed in the first only. The new
  rules have no such collapse: a category matches whenever ALL its own
  conditions hold, independently of every other category. So reproducing
  the old result needs the categories themselves to become mutually
  exclusive BANDS rather than independent thresholds: the loosest of a
  same-kind group gets the tighter ones' own threshold as an excluding
  cap, so what used to be "excluded because a tighter rule already claimed
  you" becomes "excluded because this category's own range does not reach
  you". Ties (two categories with the literal same kind and value) break
  by `category_order`, the same tie-break `min_by` gave them before -
  earlier in the order is treated as tighter, and the later one gets a
  cap equal to its own threshold, which is a range containing nobody
  (matching that it never won the old tie either).

  Different literal kinds are never banded together, even when they
  describe the same axis (`elo_below` and `elo_above` in the same
  tournament): the old code grouped by the literal `kind` string, so a
  player could genuinely receive both an "under a ceiling" AND an "above a
  floor" rating category at once, and that stays true here.
  """
  @spec migrate_legacy_rules(map(), [String.t()]) :: map()
  def migrate_legacy_rules(category_rules, category_order) when is_map(category_rules) do
    order_index = category_order |> Enum.with_index() |> Map.new()

    {legacy, kept} =
      category_rules
      |> Enum.split_with(fn {_name, rule} -> legacy_rule?(rule) end)

    banded =
      legacy
      |> Enum.group_by(fn {_name, %{"kind" => kind}} -> kind end)
      |> Enum.flat_map(fn {kind, entries} -> band_group(kind, entries, order_index) end)

    (kept ++ banded)
    |> Enum.reject(fn {_name, rule} -> not rule_owned?(rule) end)
    |> Map.new()
  end

  defp legacy_rule?(%{"kind" => kind, "value" => value})
       when kind in @legacy_kinds and is_integer(value),
       do: true

  defp legacy_rule?(_rule), do: false

  # One same-kind group -> `[{name, new_rule}]`, banded from tightest to
  # loosest per `kind_spec/1`'s `tighter:` direction, each entry (after the
  # first) capped at the previous, tighter entry's own converted value.
  defp band_group(kind, entries, order_index) do
    %{to_new: to_new, primary: primary, cap: cap, tighter: tighter} = kind_spec(kind)

    converted =
      Enum.map(entries, fn {name, %{"value" => value}} -> {name, to_new.(value)} end)

    # A name missing from `order_index` (a category `category_rules` still
    # mentions but the tournament's own `categories` list no longer does -
    # possible in a hand-edited or much older backup file, though not
    # through this app's own UI, which deletes both together) sorts last
    # rather than raising: unknown position is treated as the loosest tie,
    # same spirit as `Categories.order/2`'s own "kept but sorted after the
    # rest" for an unlisted name.
    unlisted = map_size(order_index)

    sort_key =
      case tighter do
        :min -> fn {name, value} -> {value, Map.get(order_index, name, unlisted)} end
        :max -> fn {name, value} -> {-value, Map.get(order_index, name, unlisted)} end
      end

    sorted = Enum.sort_by(converted, sort_key)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {{name, value}, index} ->
      rule =
        case Enum.at(sorted, index - 1) do
          _tighter when index == 0 -> %{primary => value}
          {_tighter_name, tighter_value} -> %{primary => value, cap => tighter_value}
        end

      {name, rule}
    end)
  end
end
