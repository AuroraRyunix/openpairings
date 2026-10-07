defmodule PairingsEngine.BoardAnnouncements.AnnouncedBoard do
  @moduledoc """
  One announced board, as announced: its number, White and Black (ids, and
  names as they were then), when and by whom. `uncertain` once a later
  check (`PairingsEngine.BoardAnnouncements.check/3`) found the preview no
  longer has it as a fixed board.
  """
  use Ecto.Schema

  schema "announced_boards" do
    belongs_to :announcement, PairingsEngine.BoardAnnouncements.Announcement
    field :label, :string
    field :white_player_id, :integer
    field :black_player_id, :integer
    field :white_name, :string, default: ""
    field :black_name, :string, default: ""
    field :announced_at, :utc_datetime
    field :announced_by_id, :integer
    field :announced_by, :string, default: ""
    field :uncertain, :boolean, default: false
  end
end
