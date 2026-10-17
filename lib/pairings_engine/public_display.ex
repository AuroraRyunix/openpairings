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
  public does not publish, or keeps the round at a lower level on the Pairings
  page - since 2026-09-28 that level, not a key here, decides whether a round's
  pairings and the standings after it are public (see `legacy_keys/0`).

  That is the line: this decides which pages exist and which columns they
  carry, never whether a shown page tells the truth.

  ## Three keys default to OFF

  `rounds_played` - the attendance column - `sex` and `performance` are opt-in,
  and they are the only keys that are. `performance` is a new number on the
  standings that nobody published before and is withheld from the rows while
  off, like `sex`. `sex` is personal data on a public page, and no
  tournament published it before it existed, so none starts showing it; unlike
  the other keys it is withheld from the snapshot entirely while off (the
  players simply carry no `sex`). The asymmetry above is about information an arbiter ALREADY
  publishes and expects to see: hiding that silently is the invisible failure.
  A column nobody had until it was built is the other way round - switching it
  on for every published tournament in the world puts a number on their public
  page that they never asked for, on an event that may already be running.

  So `default:` is part of a field, and `show?/2` reads it. Everything else
  stays exactly as it was, defaults to shown, and must: this is an exception
  for a NEW column, not a licence to make the next one quiet too.

  `flags` (2026-10-10) is the case in point: new, and still on by default. A
  flag is the federation code drawn as a picture - the same fact, already
  public wherever "Federations" is ticked and absent wherever it is not - so
  there is no number on anybody's page they did not ask for. The results site
  reads an ABSENT `flags` as off, so a snapshot from an older app draws none;
  that is its rule for this key, not this module's.

  ## One key hangs off another

  `flags` is a sub-option of `federation` (`parent/1`): a flag is drawn
  beside a federation, so with federations hidden there is nothing to draw it
  for. `show?/2` is where that is decided - `flags` is shown only when its own
  tick AND `federation` are - and the snapshot, the settings page and every
  other reader ask `show?/2`, so none of them can hold a second opinion. The
  arbiter's own tick stays stored underneath (`ticked?/2`, and `cast/2` leaves
  it alone while the box is not on the form), so switching federations back on
  brings back the choice they had made rather than a default. Until
  2026-10-11 the two were independent, which let an arbiter tick a box that
  did nothing and then go looking for the flags.
  """

  # Labels and hints are read at call time, so they follow the locale of whoever
  # is looking (the arbiter's settings page), never the one the app booted in.
  # The `key`s are the wire contract and stay English.
  use Gettext, backend: PairingsEngineWeb.Gettext

  # Sub-option -> the key it needs. One level deep, and `show?/2` relies on
  # that: a parent with a parent of its own would want a loop here.
  @parents %{"flags" => "federation"}

  @legacy_keys ~w(standings pairings)

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
      # "standings" and "pairings" were keys here until 2026-09-28 - see
      # `legacy_keys/0`. Whether a round's pairings and the standings after it
      # are public is the round's own level now.
      %{
        key: "player_cards",
        group: :pages,
        label: gettext("Player cards"),
        hint:
          gettext(
            "A page per player: every round, who they played and how it went. Off leaves " <>
              "no way to follow one player through the event."
          )
      },
      %{
        key: "byes",
        group: :pages,
        label: gettext("Byes"),
        hint: gettext("The table of players sitting a round out, and why.")
      },
      %{
        key: "screen_links",
        group: :pages,
        label: gettext("Projector and hall display links"),
        hint:
          gettext(
            "The two cards under the standings, pairings and crosstable that open the " <>
              "projector view and the hall display. Off hides the cards only; the screens " <>
              "themselves still open from their own address."
          )
      },

      # ---- about each player ----
      %{
        key: "rating",
        group: :player,
        label: gettext("Ratings"),
        hint: gettext("Each player's Elo, on the standings, the pairings and their card.")
      },
      %{
        key: "title",
        group: :player,
        label: gettext("Titles"),
        hint: gettext("GM, IM, WFM and the rest, shown before a player's name.")
      },
      %{
        key: "federation",
        group: :player,
        label: gettext("Federations"),
        hint: gettext("The three-letter country code.")
      },
      %{
        key: "flags",
        group: :player,
        label: gettext("Federation flags"),
        # On unless switched off, like its neighbours: a flag is the
        # federation code drawn, not a new fact about anybody. A sub-option
        # of "Federations" (`parent/1`): not offered, and not sent, while
        # that is off.
        hint:
          gettext(
            "A small flag beside each player's name and federation code. Part of " <>
              "Federations: not offered while that is off. None for a player under " <>
              "the FIDE flag."
          )
      },
      %{
        key: "sex",
        group: :player,
        # Opt-in, like `rounds_played`: personal data nobody published before.
        default: false,
        label: gettext("Sex"),
        hint: gettext("Each player's M/F on the public players list and standings.")
      },
      %{
        key: "performance",
        group: :player,
        # Opt-in, like `rounds_played`: a number nobody published before.
        default: false,
        label: gettext("Performance"),
        hint:
          gettext(
            "Each player's performance in this tournament on the public standings (the Perf column of the Players page)."
          )
      },
      %{
        key: "club",
        group: :player,
        label: gettext("Clubs"),
        hint: gettext("Which club a player belongs to.")
      },
      %{
        key: "category",
        group: :player,
        label: gettext("Categories"),
        hint: gettext("The tournament's own groupings, where it has them.")
      },

      # ---- about the tournament ----
      %{
        key: "city",
        group: :tournament,
        label: gettext("City"),
        hint: gettext("Where it is being played.")
      },
      %{
        key: "dates",
        group: :tournament,
        label: gettext("Dates"),
        hint: gettext("The tournament's own dates, and each round's.")
      },
      %{
        key: "arbiter",
        group: :tournament,
        label: gettext("Arbiter"),
        hint: gettext("The chief arbiter's name, as a printed pairing sheet carries it.")
      },
      %{
        key: "deputy",
        group: :tournament,
        label: gettext("Deputy arbiter"),
        hint: gettext("The deputy's name, where there is one.")
      },
      %{
        key: "time_control",
        group: :tournament,
        label: gettext("Time control"),
        hint: gettext("The tempo, as the arbiter wrote it.")
      },
      %{
        key: "fide_badge",
        group: :tournament,
        label: gettext("FIDE-rated badge"),
        hint: gettext("The note saying this event is submitted for FIDE rating.")
      },

      # ---- columns inside a page ----
      %{
        key: "tiebreaks",
        group: :columns,
        label: gettext("Tiebreak columns"),
        hint:
          gettext(
            "The numbers behind the placings. The order itself is unaffected - this hides " <>
              "the arithmetic, not the result."
          )
      },
      %{
        key: "tiebreak_working",
        group: :columns,
        label: gettext("How the tie-breaks were reached"),
        hint:
          gettext(
            "The round-by-round breakdown behind each tie-break on a player's card. Publishing " <>
              "the numbers and publishing where they came from are separate decisions."
          )
      },
      %{
        key: "rounds_played",
        group: :columns,
        # The one opt-in key - see the moduledoc.
        default: false,
        label: gettext("Rounds-present column"),
        hint:
          gettext(
            "How many rounds each player was there for: games played, a bye given because the " <>
              "field was odd, and a win by forfeit. For a prize for attending every round. Off " <>
              "unless you ask for it, and independent of the \"Rds\" column tick on your own " <>
              "screens."
          )
      },
      %{
        key: "pairing_scores",
        group: :columns,
        label: gettext("Scores on the pairings"),
        hint:
          gettext(
            "The points each player carried into the round, which is what explains why " <>
              "those two are on that board."
          )
      }
    ]
  end

  @doc """
  The groups, in display order, with a line saying what each decides.
  """
  @spec groups() :: [{group(), String.t(), String.t()}]
  def groups do
    [
      {:pages, gettext("Pages"), gettext("Which pages exist at all.")},
      {:player, gettext("About each player"), gettext("Shown beside every name.")},
      {:tournament, gettext("About the tournament"),
       gettext("The header line a printed pairing sheet carries.")},
      {:columns, gettext("Columns"), gettext("Extra detail inside a page that is shown.")}
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

  A sub-option (`parent/1`) is shown only when its parent is too: `flags`
  with `federation` off answers false whatever is stored for it. This is the
  one place that says so - the snapshot (`resolve/1`) and the settings page
  both come through here.
  """
  @spec show?(map() | nil, String.t()) :: boolean()
  def show?(display, key), do: ticked?(display, key) and offered?(display, key)

  @doc """
  What the arbiter's own tick for `key` says, parent or no parent.

  Not what is published - that is `show?/2`. This is the stored choice, which
  for a sub-option outlives its parent being switched off, and is what the
  box shows again when the parent comes back.
  """
  @spec ticked?(map() | nil, String.t()) :: boolean()
  def ticked?(display, key) when is_map(display) do
    case Map.get(display, key) do
      true -> true
      false -> false
      _unstated -> default(key)
    end
  end

  def ticked?(_nil_or_not_a_map, key), do: default(key)

  @doc """
  The key a sub-option needs, or nil for a key that stands on its own.

  `"flags"` needs `"federation"`, and that is the whole list.
  """
  @spec parent(String.t()) :: String.t() | nil
  def parent(key), do: Map.get(@parents, key)

  @doc "The sub-options of `key`, as fields, in order. Empty for nearly every key."
  @spec children(String.t()) :: [map()]
  def children(key), do: Enum.filter(fields(), &(parent(&1.key) == key))

  @doc """
  Whether the settings page has a box for `key` right now: always, except a
  sub-option whose parent is off.
  """
  @spec offered?(map() | nil, String.t()) :: boolean()
  def offered?(display, key) do
    case parent(key) do
      nil -> true
      parent -> ticked?(display, parent)
    end
  end

  @doc """
  Whether `key` is shown when the tournament has said nothing about it.

  True for every key but `rounds_played`, `sex` and `performance` - see the moduledoc. An unknown key
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
  def resolve(display), do: Map.new(keys() ++ @legacy_keys, &{&1, show?(display, &1)})

  @doc """
  The two page keys retired on 2026-09-28: `"standings"` (the placings
  table) and `"pairings"` (a page per published round). The per-round level
  on the Pairings page decides both now, so the settings page no longer
  offers them.

  They still travel, resolved like every other key: the snapshot contract
  is additive-only, and a tournament that had one switched off keeps it off
  until the arbiter shows that page again (`legacy_hidden/1`) - the upgrade
  must not put a page in front of spectators that was hidden the day before.
  """
  @spec legacy_keys() :: [String.t()]
  def legacy_keys, do: @legacy_keys

  @doc "The retired page keys (`legacy_keys/0`) this tournament still has switched off."
  @spec legacy_hidden(map() | nil) :: [String.t()]
  def legacy_hidden(display), do: Enum.reject(@legacy_keys, &show?(display, &1))

  @doc """
  Normalises submitted params into the sparse map to store.

  Checkbox params arrive as `%{"club" => "true"}` with unticked boxes simply
  absent, so anything not present is off. Only values that DIFFER from the
  key's own default are kept: the stored map is the record of what an arbiter
  changed, which keeps a future key from being silently pinned to today's
  default on every tournament that has ever visited this page. For every key
  but `rounds_played`, `sex` and `performance` that is the same thing it has always been - a map of
  what was turned off.
  """
  @spec cast(map(), map() | nil) :: map()
  def cast(params, previous \\ nil)

  def cast(params, previous) when is_map(params) do
    # Not a comprehension with `ticked? = ...` in it: an assignment in a
    # comprehension is also a FILTER on its own truthiness, so every unticked
    # box silently dropped out of the result and nothing was recorded as off.
    keys()
    |> Enum.map(&{&1, submitted?(params, previous, &1)})
    |> Enum.reject(fn {key, ticked?} -> ticked? == default(key) end)
    |> Map.new()
    # The form has no box for a retired key, so an absent one means "not on
    # this form", not "unticked": what `previous` stored for it is kept.
    |> Map.merge(Map.take(previous || %{}, @legacy_keys))
  end

  @doc """
  How many keys this tournament has turned off.

  A sub-option that is not offered (`offered?/2`) is not counted: the arbiter
  unticked one box, and being told two things are hidden would be the page
  doing sums at them.
  """
  @spec hidden_count(map() | nil) :: non_neg_integer()
  def hidden_count(display),
    do: Enum.count(keys(), &(offered?(display, &1) and not show?(display, &1)))

  # A sub-option whose parent was off when the form was drawn had no box on
  # it, so its absence is "not on this form" and not "unticked" - the same
  # distinction the retired keys get below. What was stored stands, which is
  # what brings the arbiter's choice back with the parent. A caller that
  # does send the key is believed.
  defp submitted?(params, previous, key) do
    if Map.has_key?(params, key) or offered?(previous, key) do
      truthy?(Map.get(params, key))
    else
      ticked?(previous, key)
    end
  end

  defp truthy?(value), do: value in [true, "true", "on", "1"]
end
