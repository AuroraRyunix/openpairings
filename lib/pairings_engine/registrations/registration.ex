defmodule PairingsEngine.Registrations.Registration do
  @moduledoc """
  One entry pulled from OpenResults, and the arbiter's answer to it.

  Nothing in this row is a player. A registration is a request: somebody
  filled in a web form on a server that is deliberately not allowed to write
  to a tournament, and it stays a request until an arbiter accepts it.

  There is no `changeset/2` here on purpose. Every field is either written
  once by the pull (from a payload the arbiter has not seen yet) or set by a
  decision function in `PairingsEngine.Registrations`, so a cast/2 that
  accepted external attrs would only be a way for a form to write a status.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "openresults_registrations" do
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :player, PairingsEngine.Tournaments.Player

    field :external_key, :string
    field :received_at, :utc_datetime_usec

    # The `openresults/registration` document as pulled, stored whole - see
    # the migration for why. This is also the only place in the application
    # that holds an entrant's email address.
    field :payload, :map, default: %{}

    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The `player` object inside the stored payload.

  Always a map, so callers can read a field off it without first asking
  whether the entry had a player at all - an entry pulled from a server
  running a newer or a broken form is data, not a reason to crash a page.
  """
  @spec player_data(t()) :: map()
  def player_data(%__MODULE__{payload: payload}) when is_map(payload) do
    case Map.get(payload, "player") do
      player when is_map(player) -> player
      _absent_or_wrong_shape -> %{}
    end
  end

  def player_data(%__MODULE__{}), do: %{}

  @doc """
  The entrant's name, or a placeholder.

  A nameless entry is still shown rather than hidden: the arbiter needs to
  see that something arrived and be able to discard it, and silently
  dropping it would leave them waiting for an entry that is already here.
  """
  @spec name(t()) :: String.t()
  def name(%__MODULE__{} = registration) do
    case registration |> player_data() |> Map.get("name") do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> "(no name given)"
          trimmed -> trimmed
        end

      _not_a_string ->
        "(no name given)"
    end
  end

  @doc """
  The entrant's email, or nil.

  Exists so the arbiter can reach the person - it is the reason the field
  travels at all. It is never passed to `Tournaments.create_player/2` and
  `players` has no column that could hold it.
  """
  @spec email(t()) :: String.t() | nil
  def email(%__MODULE__{} = registration) do
    case registration |> player_data() |> Map.get("email") do
      email when is_binary(email) ->
        case String.trim(email) do
          "" -> nil
          trimmed -> trimmed
        end

      _absent ->
        nil
    end
  end
end
