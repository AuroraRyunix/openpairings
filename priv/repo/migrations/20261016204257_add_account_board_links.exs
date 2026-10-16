defmodule PairingsEngine.Repo.Migrations.AddAccountBoardLinks do
  @moduledoc """
  A third kind of connect code (`PairingsEngine.BoardLink`): one that
  belongs to an account and reaches every current tournament that account
  may edit, read at the moment the box asks.

    * `board_links.user_id` - the account, for an account code; nil for a
      tournament or group code. Gone with the account: the code was only
      ever borrowing that account's access, and there is none left to
      borrow. (`created_by_id` is a record and is nilified; this is not.)
    * `board_links.label` - what the box called itself when the code was
      asked for ("Alnasl - Hall A"), for the account page. The box may say
      something else on every request afterwards; that goes in `box_name`.

  `board_link_grants` - the handshake that lets a box get an account code
  without anybody copying a secret by hand. One row per "Allow", good for
  two minutes and once. `grant_hash` is a SHA-256 of what the browser
  carries back to the box; `sealed` is the new code's secret, encrypted
  under a key derived from that same grant, so this table never holds a
  usable secret by itself.
  """
  use Ecto.Migration

  def change do
    alter table(:board_links) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :label, :string
    end

    create index(:board_links, [:user_id])

    create table(:board_link_grants) do
      add :grant_hash, :string, null: false
      add :link_id, references(:board_links, on_delete: :delete_all), null: false
      add :sealed, :binary, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:board_link_grants, [:grant_hash])
    create index(:board_link_grants, [:link_id])
  end
end
