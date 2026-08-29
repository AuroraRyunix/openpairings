defmodule PairingsEngine.Repo.Migrations.AddPublicPageControls do
  @moduledoc """
  What a published tournament shows, and whether it is findable.

  Both default to today's behaviour, which is "everything, and yes":
  publishing has always meant a full page listed on the results site's front
  page, and an upgrade must not quietly take a running tournament's ratings
  off its own standings.

  ## `public_listed`

  Whether the tournament appears in the results site's index. Off makes it
  reachable by its address and nowhere else - a club running an internal
  event for its own members wants the page, not the shopfront.

  Deliberately NOT a security control, and the UI says so: the address is an
  unguessable token, but an unlisted tournament is still world-readable to
  anyone holding it. It hides the tournament from a browsing stranger, not
  from a determined one.

  ## `public_display`

  A map of column -> boolean deciding what the public page may show. A club
  evening and an international open have genuinely different answers about
  whether everyone's Elo, club and federation belong on the open web, and
  the arbiter is the only one who knows which this is.

  Stored as a map rather than a column per field because the set will grow,
  and because a missing key has to mean "show it" - a snapshot written by an
  older app must not blank a column on a newer server.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :public_listed, :boolean, default: true, null: false
      add :public_display, :map, default: nil
    end
  end
end
