defmodule PairingsEngine.Repo.Migrations.AddFileToSentReceipts do
  @moduledoc """
  The exact file of a send, kept on its receipt: `file` (the text, at most
  2 MB, see `PairingsEngine.SentReceipts`), `file_name` (what it went out
  under) and `file_size` (bytes; nil when no file is held, which is how a
  query can tell without loading the text).

  Receipts that exist already keep all three nil: the file they covered was
  not kept and cannot be reconstructed truthfully - the inbox goes on
  offering a rebuilt copy for those and says so.
  """
  use Ecto.Migration

  def change do
    alter table(:trf_sent_receipts) do
      add :file, :text
      add :file_name, :string
      add :file_size, :integer
    end
  end
end
