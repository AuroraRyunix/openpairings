defmodule PairingsEngine.Repo.Migrations.AddPairingHidden do
  use Ecto.Migration

  # A display-only "don't show me this" flag for a fully-vacated pairing
  # row (both seats empty — see PairingsEngine.Tournaments.set_pairing_hidden/3)
  # so an arbiter can declutter the pairings view/prints of empty boards
  # left behind by two "mark absent" gestures on the same board, without
  # touching anything the 0.14.6 board-renumbering-class fix protects.
  #
  # Deliberately NOT read by PairingDisplay.compute_labels/1 or the freeze
  # wrapper (freeze_round_display_boards!/1) — hiding a row must never
  # change what any OTHER row's display_board says, and this column plays
  # no part in that computation at all, unlike display_board/display_special
  # (see add_pairing_display_board.exs). It's read only by the render-time
  # filters that skip a hidden row entirely; the row's real board number,
  # frozen display label, audit history, and TRF/export data are untouched
  # either way.
  #
  # No backfill needed: every existing pairing keeps its default `false`,
  # meaning this migration changes nothing about what's currently shown.
  def change do
    alter table(:pairings) do
      add :hidden, :boolean, null: false, default: false
    end
  end
end
