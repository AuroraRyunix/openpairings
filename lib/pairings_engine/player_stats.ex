defmodule PairingsEngine.PlayerStats do
  @moduledoc """
  Small pure helpers for SWAR-style player grid columns (age category,
  performance rating). Kept separate from `PairingsEngine.Standings` so they
  can be unit tested without building a tournament/DB fixture.
  """

  alias PairingsEngine.Tournaments.Player

  @doc """
  Picks the tightest-matching threshold PRIZE category (SWAR CATEGORIES -
  distinct from the Belgian age category above) for `player`, from a
  tournament's `category_order` (its `categories` list, in the order
  shown/defined) and `category_rules` (name => `%{"kind" =>
  "elo_below"|"elo_above"|"age_below"|"age_above", "value" => integer}`).

  A category with no rule in `category_rules` is never matched here - it
  stays a plain name the arbiter assigns by hand.

  ## Picking the tightest match

  A 1000-rated player in a tournament with both "-1200" (`elo_below`
  1200) and "-1100" (`elo_below` 1100) qualifies for both - 1000 is under
  either ceiling - and lands in **"-1100"**: the smaller ceiling is the
  more specific bracket. Symmetrically, `elo_above`/`age_above` pick the
  LARGEST qualifying floor. This is computed independently per `kind`
  (comparing an Elo ceiling against an age floor means nothing), so each
  kind present contributes at most one candidate.

  If a player ends up qualifying under more than one KIND at once - an
  Elo category and an age category both defined and both matching - the
  tie is broken by `category_order`: whichever kind's winning category
  comes FIRST in that list wins outright. Arbiters who want a specific
  kind to take priority should list it first.

  Returns `""` when nothing matches, including when the player is missing
  the data a rule needs (no rating for an Elo rule, no birth year for an
  age rule).

      iex> rules = %{"-1200" => %{"kind" => "elo_below", "value" => 1200}, "-1100" => %{"kind" => "elo_below", "value" => 1100}}
      iex> PairingsEngine.PlayerStats.assign_category(%PairingsEngine.Tournaments.Player{fide_rating: 1000, national_rating: 0}, ["-1200", "-1100"], rules)
      "-1100"
  """
  def assign_category(
        %Player{} = player,
        category_order,
        category_rules,
        current_year \\ Date.utc_today().year
      ) do
    rating = Player.rating(player)
    age = if player.birth_year, do: current_year - player.birth_year, else: nil
    order_index = category_order |> Enum.with_index() |> Map.new()

    category_order
    |> Enum.map(fn name -> {name, Map.get(category_rules, name)} end)
    |> Enum.filter(fn {_name, rule} -> rule != nil and rule_qualifies?(rule, rating, age) end)
    |> Enum.group_by(fn {_name, rule} -> rule["kind"] end)
    |> Enum.map(fn {_kind, matches} ->
      Enum.min_by(matches, fn {_n, r} -> tightness_key(r) end)
    end)
    |> case do
      [] ->
        ""

      candidates ->
        candidates |> Enum.min_by(fn {name, _r} -> Map.fetch!(order_index, name) end) |> elem(0)
    end
  end

  # An unrated player (rating 0 - `Player.rating/1` never returns a
  # negative number) still qualifies for a below-ceiling bracket: 0 is
  # genuinely under any positive threshold, and treating "no rating on
  # file" as "definitely not the lowest bracket" was backwards - an
  # unrated player is, if anything, the LEAST likely to be over a rating
  # ceiling. `elo_above` keeps its `rating > 0` guard deliberately: an
  # unrated player has no proven rating to be ABOVE anything.
  defp rule_qualifies?(%{"kind" => "elo_below", "value" => v}, rating, _age),
    do: rating < v

  defp rule_qualifies?(%{"kind" => "elo_above", "value" => v}, rating, _age),
    do: rating > 0 and rating > v

  defp rule_qualifies?(%{"kind" => "age_below", "value" => v}, _rating, age),
    do: age != nil and age < v

  defp rule_qualifies?(%{"kind" => "age_above", "value" => v}, _rating, age),
    do: age != nil and age > v

  defp rule_qualifies?(_rule, _rating, _age), do: false

  # Smaller is tighter for both kinds: a below-rule's own value (smaller
  # ceiling wins), or the negation of an above-rule's value (so a LARGER
  # floor produces a SMALLER key and still wins the `min_by`).
  defp tightness_key(%{"kind" => "elo_below", "value" => v}), do: v
  defp tightness_key(%{"kind" => "elo_above", "value" => v}), do: -v
  defp tightness_key(%{"kind" => "age_below", "value" => v}), do: v
  defp tightness_key(%{"kind" => "age_above", "value" => v}), do: -v

  # NOTE: a hardcoded Belgian KBSB age-bracket helper (`category/2`,
  # returning "-8"/"-18"/"SEN"/"S50"/"S65") used to live here and fed the
  # players grid's "Cat" column. It was removed deliberately: categories
  # are the ARBITER's to define (`Tournament.categories`, edited on the
  # Categories settings page), and a column that silently displayed
  # brackets nobody had created was showing categories that didn't exist
  # for that tournament. Age-based grouping is still available - as an
  # `age_below`/`age_above` rule on a category the arbiter created, via
  # `assign_category/4` above.

  @doc """
  Performance rating: the average rating of opponents faced in played games,
  plus 400 × (wins − losses) / games played, rounded to the nearest integer.

  `opponent_ratings` is the list of opponent ratings for each played game
  (one entry per game). Returns `nil` when no games were played (the caller
  is expected to render that as "-").

      iex> PairingsEngine.PlayerStats.performance([1800, 1700], 2, 0)
      2150
      iex> PairingsEngine.PlayerStats.performance([], 0, 0)
      nil
  """
  def performance([], _wins, _losses), do: nil

  def performance(opponent_ratings, wins, losses) do
    games_played = length(opponent_ratings)
    average = Enum.sum(opponent_ratings) / games_played
    round(average + 400 * (wins - losses) / games_played)
  end

  # ---------- FIDE expected score (We / W−We) ----------
  #
  # Table 8.1.2 of the FIDE Rating Regulations ("conversion of difference in
  # rating D into scoring probability PD"), verified against
  # https://handbook.fide.com/chapter/B022024 (FIDE Rating Regulations
  # effective from 1 March 2024). Each entry is `{upper_bound_of_D, P(higher
  # rated player scores))}` - D is looked up against the *higher*-rated
  # side's probability; the lower-rated side's is `1 - P`. Article 8.3.1
  # caps the rating difference used in this lookup at 400 both ways (applied
  # in `expected_score/1` below), so buckets past 400 (411, 432, … 735) are
  # kept only for completeness/documentation and are never actually reached.
  @fide_table [
    {3, 0.50},
    {10, 0.51},
    {17, 0.52},
    {25, 0.53},
    {32, 0.54},
    {39, 0.55},
    {46, 0.56},
    {53, 0.57},
    {61, 0.58},
    {68, 0.59},
    {76, 0.60},
    {83, 0.61},
    {91, 0.62},
    {98, 0.63},
    {106, 0.64},
    {113, 0.65},
    {121, 0.66},
    {129, 0.67},
    {137, 0.68},
    {145, 0.69},
    {153, 0.70},
    {162, 0.71},
    {170, 0.72},
    {179, 0.73},
    {188, 0.74},
    {197, 0.75},
    {206, 0.76},
    {215, 0.77},
    {225, 0.78},
    {235, 0.79},
    {245, 0.80},
    {256, 0.81},
    {267, 0.82},
    {278, 0.83},
    {290, 0.84},
    {302, 0.85},
    {315, 0.86},
    {328, 0.87},
    {344, 0.88},
    {357, 0.89},
    {374, 0.90},
    {391, 0.91},
    {411, 0.92},
    {432, 0.93},
    {456, 0.94},
    {484, 0.95},
    {517, 0.96},
    {559, 0.97},
    {619, 0.98},
    {735, 0.99}
  ]

  @doc """
  Expected score for one game given `rating_diff = own_rating - opponent_rating`,
  per FIDE Table 8.1.2, with the Article 8.3.1 cap: differences beyond ±400
  are treated as exactly 400, so the result never goes below 0.08 or above 0.92.

      iex> PairingsEngine.PlayerStats.expected_score(0)
      0.50
      iex> PairingsEngine.PlayerStats.expected_score(4)
      0.51
      iex> PairingsEngine.PlayerStats.expected_score(392)
      0.92
      iex> PairingsEngine.PlayerStats.expected_score(-735)
      0.08
  """
  def expected_score(rating_diff) when is_integer(rating_diff) do
    capped = rating_diff |> max(-400) |> min(400)
    prob = lookup_probability(abs(capped))
    if capped >= 0, do: prob, else: Float.round(1.0 - prob, 2)
  end

  defp lookup_probability(abs_diff) do
    case Enum.find(@fide_table, fn {upper, _p} -> abs_diff <= upper end) do
      {_upper, p} -> p
      nil -> 1.0
    end
  end

  @doc """
  Sum of per-game expected scores (We) for a player rated `own_rating`
  against `opponent_ratings` (one entry per counted game - the caller is
  responsible for having already excluded unplayed/forfeit games and
  unrated opponents). Returns `nil` when the player themself is unrated
  (`own_rating <= 0`) or no games were counted, matching `performance/3`'s
  "blank column" convention.

      iex> PairingsEngine.PlayerStats.we(1800, [1700, 1900])
      1.0
      iex> PairingsEngine.PlayerStats.we(0, [1700])
      nil
      iex> PairingsEngine.PlayerStats.we(1800, [])
      nil
  """
  def we(own_rating, _opponent_ratings) when own_rating <= 0, do: nil
  def we(_own_rating, []), do: nil

  def we(own_rating, opponent_ratings) do
    opponent_ratings
    |> Enum.map(&expected_score(own_rating - &1))
    |> Enum.sum()
    |> Float.round(2)
  end

  @doc """
  W − We: `own_points` (actual score in exactly the games counted for `we`)
  minus the expected score. `nil` propagates (blank column) when `we` is `nil`.

      iex> PairingsEngine.PlayerStats.w_minus_we(1.5, 1.0)
      0.5
      iex> PairingsEngine.PlayerStats.w_minus_we(1.0, nil)
      nil
  """
  def w_minus_we(_own_points, nil), do: nil
  def w_minus_we(own_points, we), do: Float.round(own_points - we, 2)
end
