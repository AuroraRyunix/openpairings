defmodule PairingsEngine.PublishingAfterRestoreTest do
  @moduledoc """
  The refusal a restore causes, worded as what it most likely is.

  A tournament first published after a backup comes back from a restore with
  no key. Publishing it again mints a new one, and the results site - which
  bound the address to the key it first saw - refuses every update with
  `key_mismatch`. The words used to blame "a different machine", and in the
  restore drill that was wrong about the machine: it was this one, before the
  restore (drill finding 3). `Backup.restore/1` now marks the copy, and a
  refusal of the key of a tournament that was already in that backup says
  what probably happened and who can fix it.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Backup, Meta, Publishing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  defp tournament do
    Repo.insert!(%Tournament{
      name: "After Restore Open",
      type: "swiss",
      rounds_count: 3,
      publish_to_openresults: true,
      public_slug: "restored-#{System.unique_integer([:positive])}"
    })
  end

  defp restored_from_backup_written(at) do
    Meta.put(
      Backup.restored_marker(),
      Jason.encode!(%{"backup_created_at" => DateTime.to_iso8601(at), "restored_at" => nil})
    )
  end

  defp refuse_the_key, do: stub(&Plug.Conn.send_resp(&1, 403, ~s({"error":"key_mismatch"})))

  test "a tournament that was in the restored backup: probably published after it, ask the operator" do
    t = tournament()
    restored_from_backup_written(DateTime.add(DateTime.utc_now(), 3600, :second))
    refuse_the_key()

    assert {:error, message} = Publishing.publish(t)
    assert message =~ "probably published after the backup this installation was restored from"
    assert message =~ "operator can move or remove it"
    refute message =~ "different machine"

    assert {:error, message} = Publishing.take_down(Tournaments.get_tournament!(t.id))
    assert message =~ "refused this tournament's key (403)"
    assert message =~ "probably published after the backup"
  end

  test "a tournament created after the restored backup was written: the ordinary words" do
    t = tournament()
    restored_from_backup_written(DateTime.add(DateTime.utc_now(), -86_400, :second))
    refuse_the_key()

    assert {:error, message} = Publishing.publish(t)
    assert message =~ "different machine"
  end

  test "a database that was never restored: the ordinary words" do
    t = tournament()
    refuse_the_key()

    assert {:error, message} = Publishing.publish(t)
    assert message =~ "different machine"
  end

  test "a refusal that is not about the key is worded as before, restored or not" do
    t = tournament()
    restored_from_backup_written(DateTime.add(DateTime.utc_now(), 3600, :second))
    stub(&Plug.Conn.send_resp(&1, 401, ~s({"error":"unauthorized"})))

    assert {:error, "the server rejected the token (401)"} = Publishing.publish(t)
  end
end
