defmodule PairingsEngine.Repo.Migrations.AddPublicPublishing do
  @moduledoc """
  The desktop side of public publishing (OpenResults'
  `docs/public-publishing.md`, "OpenPairings desktop").

  `tournaments.public_slug_minted_at` records that the results site created
  this tournament's `public_slug` for it. A desktop copy with no operator
  token publishes under a key of its own, and in that mode the SERVER picks
  the slug; the one every tournament is born with here is only a
  placeholder until then. No link or QR code may be shown or printed from a
  placeholder, because a link printed with it would be dead - and this
  column is how every surface tells the two apart. Nil on every existing row,
  which is right: in operator mode it is never consulted.

  `publish_queue.last_reason` is the failure as data rather than as an
  English sentence (`last_error` keeps the sentence, for logs), so the
  Results site settings page can word it in the arbiter's language and name
  the limit the server sent. `publish_queue.stopped_at` is a publish that
  must not be retried on a timer - the server said this tournament cannot go
  (a limit, a size cap, another installation owning the slug) and only the
  arbiter pressing "Try again" should send it again.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :public_slug_minted_at, :utc_datetime
    end

    alter table(:publish_queue) do
      add :last_reason, :text
      add :stopped_at, :utc_datetime_usec
    end
  end
end
