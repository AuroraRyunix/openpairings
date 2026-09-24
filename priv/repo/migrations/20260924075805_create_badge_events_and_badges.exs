defmodule PairingsEngine.Repo.Migrations.CreateBadgeEventsAndBadges do
  @moduledoc """
  Accreditation badges - see `PairingsEngine.Badges` and docs/badges.md.

  Two new tables and nothing else: no existing table is altered, so this is
  safe on any existing database and `down` drops exactly what `up` made.

  Images (the badge photo and the three event logos) are stored as blobs in
  these rows, the same way `tournaments.logo_data` stores the print logo, so
  a backup or a deploy carries them with no upload directory to look after.
  """
  use Ecto.Migration

  def change do
    create table(:badge_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Optional. Nilified rather than cascaded: purging a tournament must not
      # take the organiser's hand-made press and VIP badges with it.
      add :tournament_id, references(:tournaments, on_delete: :nilify_all)

      add :name, :string, null: false
      add :subtitle, :string, null: false, default: ""
      add :organiser, :string, null: false, default: ""
      add :city, :string, null: false, default: ""
      add :year, :string, null: false, default: ""
      add :qr_url, :string, null: false, default: ""
      add :conditions_title, :string, null: false, default: "USAGE CONDITIONS"
      add :usage_conditions, :text, null: false, default: ""
      add :room_count, :integer, null: false, default: 8
      add :room_names, :map, null: false, default: %{}
      add :roles, {:array, :map}, null: false, default: []

      # The header emblem (top of both sides) and the two footer logos.
      add :emblem_data, :binary
      add :emblem_content_type, :string
      add :logo_left_data, :binary
      add :logo_left_content_type, :string
      add :logo_right_data, :binary
      add :logo_right_content_type, :string

      timestamps(type: :utc_datetime)
    end

    create index(:badge_events, [:user_id])
    create index(:badge_events, [:tournament_id])

    create table(:badges) do
      add :event_id, references(:badge_events, on_delete: :delete_all), null: false

      add :first_name, :string, null: false, default: ""
      add :last_name, :string, null: false, default: ""
      add :title, :string, null: false, default: ""
      add :federation, :string, null: false, default: ""
      add :fide_id, :string, null: false, default: ""
      add :role, :string, null: false, default: ""
      add :role_color, :string, null: false, default: "#374151"
      add :room_access, {:array, :integer}, null: false, default: []

      add :photo_data, :binary
      add :photo_content_type, :string
      # "upload" or "fide" - where the stored photo came from.
      add :photo_source, :string
      # When "Fetch from FIDE" last ran for this badge, successful or not.
      add :photo_fetched_at, :utc_datetime

      # "player", "official" or "manual", and the key an import matches on.
      # No foreign key to players: a badge outlives the player row it was
      # made from, and the id only means anything inside the linked tournament.
      add :source, :string, null: false, default: "manual"
      add :source_player_id, :integer
      add :source_official_slot, :string
      # Imported fields the organiser changed by hand; a re-import leaves them alone.
      add :edited_fields, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:badges, [:event_id])

    create unique_index(:badges, [:event_id, :source_player_id],
             where: "source_player_id IS NOT NULL",
             name: :badges_event_player_index
           )

    create unique_index(:badges, [:event_id, :source_official_slot],
             where: "source_official_slot IS NOT NULL",
             name: :badges_event_official_slot_index
           )
  end
end
