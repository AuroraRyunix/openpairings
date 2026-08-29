defmodule PairingsEngine.PublicDisplay do
  @moduledoc """
  What a published tournament is allowed to show the public.

  A club evening and an international open have genuinely different answers
  about whether every player's Elo, club and federation belong on the open
  web, and the arbiter is the only person who knows which one this is. So
  they tick boxes, the ticks travel in the snapshot, and the results site
  renders what it is told.

  ## Absent means shown

  Every key defaults to `true`, and that is load-bearing in three directions
  rather than merely convenient:

    * a tournament that predates this feature stores `nil` and shows
      everything, which is exactly what it did yesterday;
    * a snapshot from an older arbiter's app omits the map, and a newer
      results site must not blank columns nobody asked it to blank;
    * a key added here later is absent from every snapshot already published,
      and must not switch a column off on tournaments that never opted out.

  The failure directions are not symmetric. Showing a column an arbiter meant
  to hide is a mistake they can see and correct in one click; hiding one they
  meant to show is invisible from the arbiter's side - their own page looks
  right - and the first they hear of it is somebody in the hall asking where
  the ratings went.

  ## What is not here

  Names, board numbers, results, pairing numbers and standings positions.
  Those are the tournament; a page without them is not a page. An arbiter who
  does not want them public does not publish.
  """

  @doc """
  Every togglable column, in the order the settings page shows them.

  `key` is what travels in the snapshot and must never be renamed - see the
  contract's own rule about additive-only changes. `label` and `hint` are
  what the arbiter reads.
  """
  @spec fields() :: [%{key: String.t(), label: String.t(), hint: String.t()}]
  def fields do
    [
      %{
        key: "rating",
        label: "Ratings",
        hint: "Each player's Elo, on the standings, the pairings and their card."
      },
      %{
        key: "title",
        label: "Titles",
        hint: "GM, IM, WFM and the rest, shown before a player's name."
      },
      %{
        key: "federation",
        label: "Federations",
        hint: "The three-letter country code."
      },
      %{
        key: "club",
        label: "Clubs",
        hint: "Which club a player belongs to."
      },
      %{
        key: "category",
        label: "Categories",
        hint: "The tournament's own groupings, where it has them."
      },
      %{
        key: "tiebreaks",
        label: "Tiebreak columns",
        hint:
          "The numbers behind the placings. The order itself is unaffected - " <>
            "turning these off hides the arithmetic, not the result."
      },
      %{
        key: "player_cards",
        label: "Player cards",
        hint:
          "A page per player: every round, who they played and how it went. " <>
            "Off leaves the standings and pairings, with no way to follow one player through."
      }
    ]
  end

  @doc "Just the keys, for validation and iteration."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(fields(), & &1.key)

  @doc """
  Whether `key` is shown, given whatever the tournament has stored.

  Takes `nil`, a partial map, and a map with keys it has never heard of,
  because all three are real: `nil` for a tournament that predates the
  feature, partial because only changed ticks are stored, and unknown keys
  because a database can outlive the code that wrote it.
  """
  @spec show?(map() | nil, String.t()) :: boolean()
  def show?(nil, _key), do: true

  def show?(display, key) when is_map(display) do
    case Map.get(display, key) do
      false -> false
      _shown_or_unstated -> true
    end
  end

  def show?(_not_a_map, _key), do: true

  @doc """
  The complete map to publish: every key, resolved to a real boolean.

  Deliberately not the sparse stored map. The stored one is an arbiter's
  edits; this is an answer, and a reader should not have to know this
  module's defaults to interpret it. Sending `%{"club" => false}` and
  expecting the other side to infer six `true`s would make the contract
  depend on a list only this app has.
  """
  @spec resolve(map() | nil) :: %{String.t() => boolean()}
  def resolve(display) do
    Map.new(keys(), &{&1, show?(display, &1)})
  end

  @doc """
  Normalises submitted params into the sparse map to store.

  Checkbox params arrive as `%{"club" => "true"}` with unticked boxes simply
  absent, so anything not present is off. Only `false` values are kept: the
  stored map is the record of what an arbiter turned OFF, which keeps a
  future key from being silently pinned to today's default on every
  tournament that has ever visited this page.
  """
  @spec cast(map()) :: map()
  def cast(params) when is_map(params) do
    for key <- keys(), not truthy?(Map.get(params, key)), into: %{}, do: {key, false}
  end

  defp truthy?(value), do: value in [true, "true", "on", "1"]
end
