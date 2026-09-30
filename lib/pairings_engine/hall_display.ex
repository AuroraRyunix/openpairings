defmodule PairingsEngine.HallDisplay do
  @moduledoc """
  How the results site's hall display runs for a tournament.

  The hall display is a full-screen page on OpenResults, meant for a TV or a
  projector in the playing hall. It cycles through a few views - the round's
  pairings, an alphabetical "find your name, find your board" list, the
  results as they come in, the top of the standings - and can carry an
  announcement from the arbiter. This module is the arbiter's side of it:
  the defaults, the settings form, and the resolved map the snapshot carries
  as `tournament.hall`.

  ## Preferences, not permissions

  Nothing here decides what the public may see. A view switched on here
  still shows only what `PairingsEngine.PublicDisplay` and each round's level
  make public, and OpenResults enforces those on its own. Switching a view
  off only takes it out of the hall screen's cycle.

  ## Stored sparse, sent resolved

  Like `public_display`, the stored map keeps only what differs from the
  defaults (nil or `%{}` is "all defaults"), and the snapshot carries every
  key resolved - a reader must not need this module's defaults to interpret
  the answer. The one exception is `announcement`, which is omitted from the
  resolved map when there is none.
  """

  import Ecto.Changeset

  @max_announcement 500

  @defaults %{
    pairings: true,
    names: true,
    results: true,
    standings: true,
    standings_top: 10,
    page_seconds: 15,
    hold_new_round: true,
    announcement: nil
  }

  @types %{
    pairings: :boolean,
    names: :boolean,
    results: :boolean,
    standings: :boolean,
    standings_top: :integer,
    page_seconds: :integer,
    hold_new_round: :boolean,
    announcement: :string
  }

  @ranges %{standings_top: 3..50, page_seconds: 5..120}

  @doc "The settings a tournament has when it has said nothing (atom keys)."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "The accepted range of an integer setting."
  @spec range(:standings_top | :page_seconds) :: Range.t()
  def range(key), do: Map.fetch!(@ranges, key)

  @doc "The longest announcement accepted, in characters."
  @spec max_announcement() :: pos_integer()
  def max_announcement, do: @max_announcement

  @doc """
  The complete map to publish as `tournament.hall`: every key, string-keyed,
  with defaults filled in. `announcement` is present only when there is one.

  Takes nil, a partial map, and junk, because a stored map can come from an
  imported file: a value of the wrong type or out of range falls back to that
  key's default, and an announcement that is blank or too long is dropped.
  """
  @spec resolve(map() | nil) :: %{String.t() => boolean() | integer() | String.t()}
  def resolve(stored) do
    stored = if is_map(stored), do: stored, else: %{}

    resolved =
      for {key, default} <- @defaults, key != :announcement, into: %{} do
        name = Atom.to_string(key)
        {name, stored_value(key, Map.get(stored, name), default)}
      end

    case stored_announcement(Map.get(stored, "announcement")) do
      nil -> resolved
      text -> Map.put(resolved, "announcement", text)
    end
  end

  @doc """
  The settings form's changeset: the resolved stored settings as data, the
  submitted params as changes. Checkbox params arrive as `"true"`/`"false"`
  (core_components' checkbox sends a hidden `"false"`), numbers as strings.
  """
  @spec changeset(map() | nil, map()) :: Ecto.Changeset.t()
  def changeset(stored, params \\ %{}) do
    resolved = resolve(stored)
    data = Map.new(@types, fn {key, _type} -> {key, Map.get(resolved, Atom.to_string(key))} end)
    keys = Map.keys(@types)

    {data, @types}
    |> cast(params, keys)
    |> update_change(:announcement, &normalise_announcement/1)
    |> validate_required(keys -- [:announcement])
    |> validate_range(:standings_top)
    |> validate_range(:page_seconds)
    |> validate_length(:announcement, max: @max_announcement)
  end

  @doc """
  Validates submitted params against the stored settings: `{:ok, stored}`
  with the sparse map to store, or `{:error, changeset}` with the action set,
  ready for `to_form/2`.
  """
  @spec cast(map() | nil, map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def cast(stored, params) when is_map(params) do
    with {:ok, settings} <- stored |> changeset(params) |> apply_action(:update) do
      {:ok,
       settings
       |> Enum.reject(fn {key, value} -> value == Map.fetch!(@defaults, key) end)
       |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)}
    end
  end

  @doc """
  Trims an announcement and turns CRLF (and a lone CR) into LF. Blank is nil.
  """
  @spec normalise_announcement(String.t() | nil) :: String.t() | nil
  def normalise_announcement(nil), do: nil

  def normalise_announcement(text) when is_binary(text) do
    case text |> String.replace(["\r\n", "\r"], "\n") |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp validate_range(changeset, key) do
    first..last//_ = range(key)
    validate_number(changeset, key, greater_than_or_equal_to: first, less_than_or_equal_to: last)
  end

  defp stored_value(key, value, default) do
    case {Map.fetch!(@types, key), value} do
      {:boolean, value} when is_boolean(value) -> value
      {:integer, value} when is_integer(value) -> if value in range(key), do: value, else: default
      _junk -> default
    end
  end

  defp stored_announcement(text) when is_binary(text) do
    case normalise_announcement(text) do
      nil -> nil
      text -> if String.length(text) > @max_announcement, do: nil, else: text
    end
  end

  defp stored_announcement(_junk), do: nil
end
