defmodule PairingsEngine.Repo.Migrations.AddReachToBoardLinks do
  use Ecto.Migration

  # A desktop copy can let a box elsewhere in the hall connect
  # (`PairingsEngineWeb.BoardLan`). A code made for that says so:
  #
  #   * `reach` - "lan" for a code made for a box on the network, nil for
  #     every other code there has ever been;
  #   * `address` - the address that code was made with
  #     (`http://192.168.1.20:4747`), so the page can say that this PC has
  #     moved since and the box holding the code is calling an empty room;
  #   * `expires_at` - a network code crossed a hall network in plain http,
  #     so it stops working by itself. Nil: never, which is every other code.
  def change do
    alter table(:board_links) do
      add :reach, :string
      add :address, :string
      add :expires_at, :utc_datetime
    end
  end
end
