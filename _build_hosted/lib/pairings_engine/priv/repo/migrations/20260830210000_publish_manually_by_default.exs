defmodule PairingsEngine.Repo.Migrations.PublishManuallyByDefault do
  use Ecto.Migration

  import Ecto.Query

  # `publish_mode` defaulted to "immediate": a round reached the public page
  # the instant the engine handed it back, before the arbiter had looked at
  # it. The new default is "manual" - see `Tournament`'s own comment.
  #
  # Existing rows are moved ONLY where the change cannot surprise anyone:
  # a tournament that has never published (`openresults_key IS NULL`) has no
  # audience to stop serving, so switching it is free. One that IS publishing
  # is left exactly as it is, because silently ceasing to publish mid-event
  # is its own disaster and the opposite of what this fixes.
  #
  # Down leaves everything alone. It cannot tell a row it moved from one an
  # arbiter chose, and guessing would undo a deliberate setting.
  def up do
    from(t in "tournaments",
      where: is_nil(t.openresults_key) and t.publish_mode == "immediate",
      update: [set: [publish_mode: "manual"]]
    )
    |> repo().update_all([])
  end

  def down, do: :ok
end
