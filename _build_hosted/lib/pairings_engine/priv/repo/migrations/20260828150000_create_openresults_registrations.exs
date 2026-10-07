defmodule PairingsEngine.Repo.Migrations.CreateOpenresultsRegistrations do
  @moduledoc """
  Entries the public form collected, mirrored onto the arbiter's machine.

  The direction is the whole point: OpenResults never writes to a tournament.
  It holds a queue, this machine pulls it, and the arbiter decides. So there
  has to be somewhere here to put a pulled entry that is not yet a player -
  a registration is a REQUEST, and the row below is that request plus the
  arbiter's answer to it.

  ## Why the payload is stored whole

  Two reasons, neither of them laziness.

  A pull needs the network and a decision does not. An arbiter can pull once
  on the hotel wifi that works for ten seconds and then review the entries
  in the playing hall, which is the same reason `publish_queue` exists one
  migration back.

  And the payload is the OTHER half of a contract that promises to stay
  additive. Storing it verbatim means a field the public form adds next
  month arrives here without a migration, and the review page can start
  showing it whenever somebody teaches it to.

  ## `external_key`, not the server's id

  The handle a decision hangs on has to survive being pulled twice, and this
  side cannot assume what the server puts in a listing - the route is newer
  than this table. So `external_key` is derived by
  `PairingsEngine.Registrations`: the server's row id when the listing
  carries one, and a fingerprint of the entry when it does not. Either way
  it is unique per tournament, which is what stops a re-pull resurrecting an
  entry the arbiter already turned away.

  ## The email

  `payload` holds the one piece of personal data in this feature, and this
  table is where it stops. `players` has no email column at all, so
  accepting an entry cannot carry it into a snapshot, a TRF or a public
  page even by accident - see `PairingsEngine.Snapshot`'s allowlist for the
  same guarantee stated from the other end.
  """
  use Ecto.Migration

  def change do
    create table(:openresults_registrations) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false

      # Stable per tournament across pulls - see the moduledoc.
      add :external_key, :string, null: false

      # When the entry was submitted, as best this side can tell. The server
      # stamps its own clock on arrival because a public submitter's claimed
      # time is forged trivially; if a listing does not carry that, the
      # claimed value is kept anyway, because "roughly when" is still the
      # order an arbiter reads a queue in.
      add :received_at, :utc_datetime_usec

      # The `openresults/registration` document exactly as pulled.
      add :payload, :map, null: false, default: %{}

      # pending | accepted | discarded. Nothing else is written here; a value
      # this app does not recognise would simply never be listed.
      add :status, :string, null: false, default: "pending"

      # The player an accepted entry became. Nilified rather than cascading:
      # deleting a player is an ordinary correction, and it must not silently
      # delete the record of the entry that person submitted.
      add :player_id, references(:players, on_delete: :nilify_all)

      add :decided_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # The one rule this table enforces: an entry is pulled once. Everything
    # else about "have I already dealt with this?" follows from it.
    create unique_index(:openresults_registrations, [:tournament_id, :external_key])

    # The review page's only query: this tournament's entries, by status.
    create index(:openresults_registrations, [:tournament_id, :status])
  end
end
