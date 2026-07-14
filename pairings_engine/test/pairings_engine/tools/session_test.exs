defmodule PairingsEngine.Tools.SessionTest do
  # async: true — pure ETS, no database. The store under test is the app's
  # own singleton (started by PairingsEngine.Application); every test uses
  # its own random token, so concurrent tests never collide.
  use ExUnit.Case, async: true

  alias PairingsEngine.Tools.Session

  test "put/1 returns a random token that reads the data back" do
    token = Session.put(%{hello: "world"})

    assert is_binary(token)
    assert {:ok, %{hello: "world"}} = Session.get(token)
  end

  test "tokens are unguessable-length url64 and unique" do
    tokens = for _ <- 1..50, do: Session.token()

    assert Enum.uniq(tokens) == tokens
    # 24 random bytes -> 32 chars of unpadded url-safe base64.
    assert Enum.all?(tokens, &(String.length(&1) == 32))
    assert Enum.all?(tokens, &Regex.match?(~r/^[A-Za-z0-9_-]+$/, &1))
  end

  test "get/1 on an unknown token is :error" do
    assert Session.get("no-such-token") == :error
  end

  test "put/2 upserts under the same token" do
    token = Session.put(%{v: 1})
    assert ^token = Session.put(token, %{v: 2})
    assert {:ok, %{v: 2}} = Session.get(token)
  end

  test "an entry past its TTL reads back as :error and is removed" do
    token = Session.put(Session.token(), %{v: 1}, 0)

    assert Session.get(token) == :error
    # Lazy expiry actually deleted the row, not just hid it.
    assert :ets.lookup(Session, token) == []
  end

  test "the periodic sweep removes expired entries nobody reads again" do
    expired = Session.put(Session.token(), %{v: :old}, 0)
    alive = Session.put(Session.token(), %{v: :new})

    send(Process.whereis(Session), :sweep)
    # :sys.get_state round-trips through the GenServer's mailbox, so the
    # :sweep message above is guaranteed handled once this returns.
    :sys.get_state(Session)

    assert :ets.lookup(Session, expired) == []
    assert {:ok, %{v: :new}} = Session.get(alive)
  end

  test "delete/1 removes an entry" do
    token = Session.put(%{v: 1})

    assert Session.delete(token) == :ok
    assert Session.get(token) == :error
  end
end
