defmodule PairingsEngine.Badges.Badge do
  @moduledoc """
  One person's accreditation badge.

  `source` says where it came from: `"player"` (matched on re-import by
  `source_player_id`), `"official"` (matched by `source_official_slot`, one of
  `chief`, `deputy1`, `deputy2`, `arbiterN`) or `"manual"` (never touched by an
  import). `edited_fields` lists the imported fields the organiser has changed
  by hand on an imported badge; an import leaves those alone from then on. See
  `PairingsEngine.Badges` for how both are maintained.

  The photo blob, where it came from, and the import bookkeeping are never
  cast - only the context writes them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PairingsEngine.Badges.Event

  # The fields an import writes, and so the ones whose hand edits are tracked.
  @imported_fields ~w(first_name last_name title federation fide_id role role_color)a

  schema "badges" do
    field :first_name, :string, default: ""
    field :last_name, :string, default: ""
    field :title, :string, default: ""
    field :federation, :string, default: ""
    field :fide_id, :string, default: ""
    field :role, :string, default: ""
    field :role_color, :string, default: "#374151"
    field :room_access, {:array, :integer}, default: []

    field :photo_data, :binary, redact: true
    field :photo_content_type, :string
    field :photo_source, :string
    field :photo_fetched_at, :utc_datetime

    field :source, :string, default: "manual"
    field :source_player_id, :integer
    field :source_official_slot, :string
    field :edited_fields, {:array, :string}, default: []

    belongs_to :event, Event

    timestamps(type: :utc_datetime)
  end

  @doc "The fields an import fills in."
  def imported_fields, do: @imported_fields

  @doc "The fields the badge editor may change."
  def changeset(badge, attrs) do
    badge
    |> cast(attrs, [:first_name, :last_name, :title, :federation, :fide_id, :role, :role_color])
    |> update_change(:first_name, &String.trim/1)
    |> update_change(:last_name, &String.trim/1)
    |> update_change(:title, &String.trim/1)
    |> update_change(:federation, &String.trim/1)
    |> update_change(:fide_id, &String.trim/1)
    |> validate_length(:first_name, max: 60)
    |> validate_length(:last_name, max: 60)
    |> validate_length(:title, max: 10)
    |> validate_length(:federation, max: 40)
    |> validate_length(:role, max: 40)
    |> validate_format(:fide_id, ~r/^\d{0,10}$/, message: "must be digits only")
    |> validate_change(:role_color, fn :role_color, color ->
      if Event.valid_color?(color), do: [], else: [role_color: "must be written as #RRGGBB"]
    end)
  end

  @doc "Sets which numbered rooms the badge opens, keeping only rooms the event has."
  def room_access_changeset(badge, rooms, room_count) do
    rooms =
      rooms
      |> Enum.filter(&(is_integer(&1) and &1 >= 1 and &1 <= room_count))
      |> Enum.uniq()
      |> Enum.sort()

    change(badge, room_access: rooms)
  end

  @doc "True when the badge came from the linked tournament rather than by hand."
  def imported?(%__MODULE__{source: source}), do: source in ["player", "official"]

  @doc "The name as printed, for lists and flash messages."
  def display_name(%__MODULE__{first_name: first, last_name: last}) do
    [first, last] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
  end
end
