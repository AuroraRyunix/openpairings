defmodule PairingsEngine.Repo.Migrations.CreateKbsbClubs do
  @moduledoc """
  A durable club-number -> club-name mirror, kept SEPARATE from
  `kbsb_players` (which is fully replaced on every sync).

  The public monthly players.sqlite carries no club names at all - only
  `Club` (a number). A name for that number can come from a `clubs` table
  bundled in the same zip, or from a second optional "Belgian club names
  URL" setting - either, neither, or both, on any given month. This table
  is where a name learned from either source is remembered, so that a
  later month's file that omits a club (or a maintainer who stops
  publishing the clubs URL) does not make an already-known name
  disappear - see `PairingsEngine.Federations.BEL.Clubs`.
  """
  use Ecto.Migration

  def change do
    create table(:kbsb_clubs, primary_key: false) do
      add :club_number, :integer, primary_key: true
      add :name, :string, null: false
    end
  end
end
