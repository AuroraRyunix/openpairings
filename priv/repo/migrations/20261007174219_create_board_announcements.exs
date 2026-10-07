defmodule PairingsEngine.Repo.Migrations.CreateBoardAnnouncements do
  @moduledoc """
  Boards of a round not yet paired that the arbiter announced - put the name
  cards out for - from the next-round preview
  (`PairingsEngine.BoardAnnouncements`).

    * `board_announcements` - one per tournament and round: the state of
      the data the announced boards were certain for (`base`, the digest
      `PairingsEngine.NextRoundPreview.base_state/2` gives, and the round's
      results then), and the paired round whose differences the arbiter has
      acknowledged.
    * `announced_boards` - each board as announced: its number, White and
      Black (ids and names as they were), when and by whom, and whether a
      later check found it no longer certain.

  Player ids are plain integers: a player deleted later must not take the
  record of what was announced with them.
  """
  use Ecto.Migration

  def change do
    create table(:board_announcements) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :round, :integer, null: false
      add :base, :binary
      add :round_results, :map, null: false, default: %{}
      add :acknowledged_round_id, :integer
      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_announcements, [:tournament_id, :round])

    create table(:announced_boards) do
      add :announcement_id, references(:board_announcements, on_delete: :delete_all), null: false

      add :label, :string, null: false
      add :white_player_id, :integer, null: false
      add :black_player_id, :integer, null: false
      add :white_name, :string, null: false, default: ""
      add :black_name, :string, null: false, default: ""
      add :announced_at, :utc_datetime, null: false
      add :announced_by_id, :integer
      add :announced_by, :string, null: false, default: ""
      add :uncertain, :boolean, null: false, default: false
    end

    create index(:announced_boards, [:announcement_id])
  end
end
