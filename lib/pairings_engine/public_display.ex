defmodule PairingsEngine.PublicDisplay do
  @moduledoc """
  What a published tournament is allowed to show the public.

  A club evening and an international open have genuinely different answers
  about whose Elo, club and date of play belong on the open web, and the
  arbiter is the only person who knows which one this is. So they tick boxes,
  the ticks travel in the snapshot, and the results site renders what it is
  told.

  ## Absent means shown

  Every key defaults to `true`, and that is load-bearing in three directions
  rather than merely convenient:

    * a tournament that predates a key shows it, which is exactly what it did
      yesterday;
    * a snapshot from an older arbiter's app omits the key, and a newer results
      site must not blank a column nobody asked it to blank;
    * a key added here later is absent from every snapshot already published,
      and must not switch something off on tournaments that never opted out.

  The failure directions are not symmetric. Showing something an arbiter meant
  to hide is a mistake they can see and correct in one click; hiding something
  they meant to show is invisible from the arbiter's side - their own screens
  look right - and the first they hear of it is somebody in the hall asking
  where the ratings went.

  ## What is not here, and will not be

  Names, board numbers, results, pairing numbers and standings positions **when
  the page they live on is shown at all**. Those are the tournament; a
  standings page without names is not a page. An arbiter who does not want them
  public does not publish, or switches that whole page off with the keys in the
  `:pages` group.

  That is the line: this decides which pages exist and which columns they
  carry, never whether a shown page tells the truth.

  ## One key defaults to OFF

  `rounds_played` - the attendance column - is opt-in, and it is the only key
  that is. The asymmetry above is about information an arbiter ALREADY
  publishes and expects to see: hiding that silently is the invisible failure.
  A column nobody had until it was built is the other way round - switching it
  on for every published tournament in the world puts a number on their public
  page that they never asked for, on an event that may already be running.

  So `default:` is part of a field, and `show?/2` reads it. Everything else
  stays exactly as it was, defaults to shown, and must: this is an exception
  for a NEW column, not a licence to make the next one quiet too.
  """

  @typedoc "Which part of the public page a key controls."
  @type group :: :pages | :player | :tournament | :columns

  @doc """
  Every togglable key, in the order the settings page shows them.

  `key` is what travels in the snapshot and must never be renamed - see the
  contract's own rule about additive-only changes. Everything else is what the
  arbiter reads.
  """
  @spec fields() :: [
          %{
            key: String.t(),
            label: String.t(),
            hint: String.t(),
            group: group(),
            default: boolean()
          }
        ]
  def fields do
    [
      # ---- whole pages ----
      %{
        key: "standings",
        group: :pages,
        label: "Standings",
        hint:
          "The placings table. Off publishes the rounds without a league table - " <>
            "some arbiters withhold standings until the last round is in."
      },
      %{
        key: "pairings",
        group: :pages,
        label: "Round pairings",
        hint:
          "A page per published round, with the boards and their results. Off leaves " <>
            "the standings and no way to see who played whom."
      },
      %{
        key: "player_cards",
        group: :pages,
        label: "Player cards",
        hint:
          "A page per player: every round, who they played and how it went. Off leaves " <>
            "no way to follow one player through the event."
      },
      %{
        key: "byes",
        group: :pages,
        label: "Byes",
        hint: "The table of players sitting a round out, and why."
      },

      # ---- about each player ----
      %{
        key: "rating",
        group: :player,
        label: "Ratings",
        hint: "Each player's Elo, on the standings, the pairings and their card."
      },
      %{
        key: "title",
        group: :player,
        label: "Titles",
        hint: "GM, IM, WFM and the rest, shown before a player's name."
      },
      %{
        key: "federation",
        group: :player,
        label: "Federations",
        hint: "The three-letter country code."
      },
      %{
        key: "club",
        group: :player,
        label: "Clubs",
        hint: "Which club a player belongs to."
      },
      %{
        key: "category",
        group: :player,
        label: "Categories",
        hint: "The tournament's own groupings, where it has them."
      },

      # ---- about the tournament ----
      %{
        key: "city",
        group: :tournament,
        label: "City",
        hint: "Where it is being played."
      },
      %{
        key: "dates",
        group: :tournament,
        label: "Dates",
        hint: "The tournament's own dates, and each round's."
      },
      %{
        key: "arbiter",
        group: :tournament,
        label: "Arbiter",
        hint: "The chief arbiter's name, as a printed pairing sheet carries it."
      },
      %{
        key: "deputy",
        group: :tournament,
        label: "Deputy arbiter",
        hint: "The deputy's name, where there is one."
      },
      %{
        key: "time_control",
        group: :tournament,
        label: "Time control",
        hint: "The tempo, as the arbiter wrote it."
      },
      %{
        key: "fide_badge",
        group: :tournament,
        label: "FIDE-rated badge",
        hint: "The note saying this event is submitted for FIDE rating."
      },

      # ---- columns inside a page ----
      %{
        key: "tiebreaks",
        group: :columns,
        label: "Tiebreak columns",
        hint:
          "The numbers behind the placings. The order itself is unaffected - this hides " <>
            "the arithmetic, not the result."
      },
      %{
        key: "tiebreak_working",
        group: :columns,
        label: "How the tie-breaks were reached",
        hint:
          "The round-by-round breakdown behind each tie-break on a player's card. Publishing " <>
            "the numbers and publishing where they came from are separate decisions."
      },
      %{
        key: "rounds_played",
        group: :columns,
        # The one opt-in key - see the moduledoc.
        default: false,
        label: "Rounds-present column",
        hint:
          "How many rounds each player was there for: games played, a bye given because the " <>
            "field was odd, and a win by forfeit. For a prize for attending every round. Off " <>
            "unless you ask for it, and independent of the \"Rds\" column tick on your own " <>
            "screens."
      },
      %{
        key: "pairing_scores",
        group: :columns,
        label: "Scores on the pairings",
        hint:
          "The points each player carried into the round, which is what explains why " <>
            "those two are on that board."
      }
    ]
  end

  @doc """
  The groups, in display order, with a line saying what each decides.
  """
  @spec groups() :: [{group(), String.t(), String.t()}]
  def groups do
    [
      {:pages, "Pages", "Which pages exist at all."},
      {:player, "About each player", "Shown beside every name."},
      {:tournament, "About the tournament", "The header line a printed pairing sheet carries."},
      {:columns, "Columns", "Extra detail inside a page that is shown."}
    ]
  end

  @doc "The fields in one group, in order."
  @spec fields(group()) :: [map()]
  def fields(group), do: Enum.filter(fields(), &(&1.group == group))

  @doc "Just the keys, for validation and iteration."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(fields(), & &1.key)

  @doc """
  Whether `key` is shown, given whatever the tournament has stored.

  Takes `nil`, a partial map, and a map with keys it has never heard of,
  because all three are real: `nil` for a tournament that predates the feature,
  partial because only changed ticks are stored, and unknown keys because a
  database can outlive the code that wrote it.
  """
  @spec show?(map() | nil, String.t()) :: boolean()
  def show?(nil, key), do: default(key)

  def show?(display, key) when is_map(display) do
    case Map.get(display, key) do
      true -> true
      false -> false
      _unstated -> default(key)
    end
  end

  def show?(_not_a_map, key), do: default(key)

  @doc """
  Whether `key` is shown when the tournament has said nothing about it.

  True for every key but `rounds_played` - see the moduledoc. An unknown key
  (a database outliving the code that wrote it) answers true, which is the
  same direction the rest of this module leans.
  """
  @spec default(String.t()) :: boolean()
  def default(key) do
    case Enum.find(fields(), &(&1.key == key)) do
      nil -> true
      field -> Map.get(field, :default, true)
    end
  end

  @doc """
  The complete map to publish: every key, resolved to a real boolean.

  Deliberately not the sparse stored map. The stored one is an arbiter's edits;
  this is an answer, and a reader should not have to know this module's
  defaults to interpret it. Sending `%{"club" => false}` and expecting the
  other side to infer the rest would make the contract depend on a list only
  this app has.
  """
  @spec resolve(map() | nil) :: %{String.t() => boolean()}
  def resolve(display), do: Map.new(keys(), &{&1, show?(display, &1)})

  @doc """
  Normalises submitted params into the sparse map to store.

  Checkbox params arrive as `%{"club" => "true"}` with unticked boxes simply
  absent, so anything not present is off. Only values that DIFFER from the
  key's own default are kept: the stored map is the record of what an arbiter
  changed, which keeps a future key from being silently pinned to today's
  default on every tournament that has ever visited this page. For every key
  but `rounds_played` that is the same thing it has always been - a map of
  what was turned off.
  """
  @spec cast(map()) :: map()
  def cast(params) when is_map(params) do
    # Not a comprehension with `ticked? = ...` in it: an assignment in a
    # comprehension is also a FILTER on its own truthiness, so every unticked
    # box silently dropped out of the result and nothing was recorded as off.
    keys()
    |> Enum.map(&{&1, truthy?(Map.get(params, &1))})
    |> Enum.reject(fn {key, ticked?} -> ticked? == default(key) end)
    |> Map.new()
  end

  @doc "How many keys this tournament has turned off."
  @spec hidden_count(map() | nil) :: non_neg_integer()
  def hidden_count(display), do: Enum.count(keys(), &(not show?(display, &1)))

  defp truthy?(value), do: value in [true, "true", "on", "1"]
end
