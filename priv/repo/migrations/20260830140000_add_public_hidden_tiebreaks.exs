defmodule PairingsEngine.Repo.Migrations.AddPublicHiddenTiebreaks do
  use Ecto.Migration

  # Which of this tournament's tie-breaks are kept off the public page.
  #
  # A list rather than another key in `public_display`, because that map is
  # resolved to a boolean per key when it is published and a list would not
  # survive the trip. It is also a different kind of choice: the display map
  # holds a fixed set of columns every tournament has, this holds codes that
  # only exist because this arbiter chose them.
  #
  # Empty means every tie-break is shown, which is what publishing meant
  # before there was a choice - the same absent-means-shown rule the display
  # map uses.
  def change do
    alter table(:tournaments) do
      add :public_hidden_tiebreaks, {:array, :string}, null: false, default: []
    end
  end
end
