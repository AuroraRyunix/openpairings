defmodule PairingsEngine.Accounts.TournamentDefaults do
  @moduledoc """
  What a new tournament is filled in with, per account - `users.tournament_defaults`.

  An organiser who runs the same club evening every week types the same
  place, the same federation and the same rate of play every time. These
  are the settings that are (a) the same from one event to the next for most
  people and (b) honoured by the "New tournament" form, either as a pre-filled
  field the organiser can still change before pressing Create
  (`form_params/1`) or as a value the create path adds when the form does not
  carry that field at all (`hidden_params/1`).

  ## Only what the create path can honour

  Every field here goes through `Tournament.changeset/2` on create, so
  nothing is stored that the tournament would then refuse or silently drop.
  Deliberately NOT here, and why:

    * **Tie-breaks.** The list a tournament starts with is
      `Tiebreaks.fide_defaults/1` for its type, and the right list for a
      round robin, a Swiss and a team event are different lists. One stored
      list would be the wrong one for every type but one.
    * **Chief arbiter.** It is a name AND a FIDE id kept together by the
      officials picker (`PairingsEngineWeb.ArbiterCombo`); a default that
      filled one half would produce a report with a name and no id.
    * **Scoring.** Club scoring (3-1-0, presence points) is set per event
      on the Scoring page and a new tournament starts with FIDE's, which is
      what a FIDE-rated event needs.

  ## Blank means "no default"

  Every field is optional, and an empty one leaves the form exactly as it
  was before this existed - the app's own default for that field. Nothing
  here can make a new tournament worse than the default it would have got.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PairingsEngine.RateOfPlay
  alias PairingsEngine.Tournaments.Tournament

  @primary_key false
  embedded_schema do
    field :pairing_system, :string
    field :rounds_count, :integer
    field :standard, :string
    field :rate_of_play, :string
    field :city, :string
    field :federation, :string
    field :organizer, :string
    field :publish_mode, :string
    field :publish_delay_minutes, :integer
  end

  @fields ~w(pairing_system rounds_count standard rate_of_play city federation organizer
             publish_mode publish_delay_minutes)a

  # On the "New tournament" form itself, where the organiser sees them and
  # can still change them before pressing Create.
  @form_fields ~w(pairing_system rounds_count standard rate_of_play city)a

  # Not on that form. Added by the create path under whatever the form sent,
  # so they reach the tournament without the form needing to show them.
  @hidden_fields ~w(federation organizer publish_mode publish_delay_minutes)a

  def changeset(defaults, attrs) do
    defaults
    |> cast(attrs, @fields, empty_values: [nil, ""])
    |> update_change(:city, &trim/1)
    |> update_change(:organizer, &trim/1)
    |> update_change(:rate_of_play, &trim/1)
    |> update_change(:federation, &(&1 |> trim() |> String.upcase()))
    |> validate_inclusion(:pairing_system, Tournament.pairing_systems())
    |> validate_inclusion(:standard, Enum.map(RateOfPlay.standard_options(), &elem(&1, 0)))
    |> validate_inclusion(:publish_mode, Tournament.publish_modes())
    |> validate_number(:rounds_count,
      greater_than: 0,
      less_than_or_equal_to: Tournament.max_rounds()
    )
    |> validate_number(:publish_delay_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 24 * 60
    )
    |> validate_format(:federation, ~r/\A[A-Z]{3}\z/,
      message: "must be a three-letter FIDE federation code"
    )
    |> validate_length(:city, max: 100)
    |> validate_length(:organizer, max: 200)
    |> validate_length(:rate_of_play, max: 200)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  @doc "Every field an account may store, in the order the account page shows them."
  def fields, do: @fields

  @doc """
  The stored defaults as the string-keyed params the "New tournament" form
  is bound to - only the fields that form shows, and only the ones that are
  set. Merged OVER the form's own initial values, so an unset default leaves
  the app's default in place.
  """
  def form_params(nil), do: %{}
  def form_params(%__MODULE__{} = defaults), do: params(defaults, @form_fields)

  @doc """
  The stored defaults the "New tournament" form does not show, as create
  params. The create path merges the submitted form OVER these, so anything
  the form does carry always wins.

  `publish_delay_minutes` travels only with an automation that has the
  pairings step it delays: on its own it would be a delay nothing reads. A
  `publish_mode` from before 2026-09-28 (the migration converts stored ones,
  this covers anything it could not reach) is converted the same way,
  rather than handed to a changeset that would refuse it and with it the
  whole new tournament.
  """
  def hidden_params(nil), do: %{}

  def hidden_params(%__MODULE__{} = defaults) do
    params =
      defaults
      |> params(@hidden_fields)
      |> Map.update("publish_mode", nil, &current_publish_mode/1)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if Tournament.auto_publish_level(params["publish_mode"]) >= 1 do
      params
    else
      Map.delete(params, "publish_delay_minutes")
    end
  end

  defp current_publish_mode(mode) do
    if Tournament.legacy_publish_mode?(mode),
      do: Tournament.legacy_publish_mode(mode, nil),
      else: mode
  end

  @doc "Whether any default at all is stored."
  def any?(nil), do: false
  def any?(%__MODULE__{} = defaults), do: params(defaults, @fields) != %{}

  defp params(defaults, fields) do
    fields
    |> Enum.map(&{Atom.to_string(&1), Map.get(defaults, &1)})
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end
end
