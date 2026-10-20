defmodule PairingsEngine.Repo.Migrations.CreateManubriumDevices do
  @moduledoc """
  Manubrium, the full app (docs/manubrium.md, "Full app"): a phone with the
  native app installed is a *device* of an account, holding a long-lived
  token of its own. The server keeps only the token's hash.

    * `manubrium_connect_codes` - the one-time, short-lived secrets a
      signed-in account shows as a QR so the app can trade one for a device
      token. Hash only, used once, expired after minutes.
    * `manubrium_devices` - the devices, with the hash of their token, the
      last time they were heard from, and when they were revoked.
    * `mobile_enrollments.device_id` - the phone code a device enters
      results under in one tournament, so the app shares the hall's queue,
      its compare-and-set and its audit trail instead of having its own.
  """
  use Ecto.Migration

  def change do
    create table(:manubrium_connect_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :secret_hash, :string, null: false
      add :base_url, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:manubrium_connect_codes, [:secret_hash])
    create index(:manubrium_connect_codes, [:user_id])

    create table(:manubrium_devices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false, default: ""
      add :platform, :string, null: false, default: ""
      add :token_hash, :string, null: false
      add :token_hint, :string, null: false, default: ""
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:manubrium_devices, [:token_hash])
    create index(:manubrium_devices, [:user_id])

    alter table(:mobile_enrollments) do
      add :device_id, references(:manubrium_devices, on_delete: :nilify_all)
    end

    create index(:mobile_enrollments, [:device_id])
  end
end
