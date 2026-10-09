defmodule PairingsEngine.TournamentGroups.Member do
  @moduledoc """
  One tournament's place in a `PairingsEngine.TournamentGroups.Group`: which
  group, where in the switcher, and under what short label.

  A tournament is in at most one group (a unique index on `tournament_id`).
  `label` is optional - blank means the switcher uses the tournament's own
  name. `group_id`, `tournament_id` and `position` are set by
  `PairingsEngine.TournamentGroups`, never cast from a form.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_label 40

  schema "tournament_group_members" do
    field :label, :string
    field :position, :integer

    belongs_to :group, PairingsEngine.TournamentGroups.Group
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament

    timestamps(type: :utc_datetime)
  end

  @doc false
  def max_label, do: @max_label

  @doc "Only the label is the arbiter's to type."
  def label_changeset(member, attrs) do
    member
    |> cast(attrs, [:label])
    |> update_change(:label, &blank_to_nil/1)
    |> validate_length(:label, max: @max_label)
  end

  defp blank_to_nil(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(label), do: label
end
