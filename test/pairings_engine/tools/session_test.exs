defmodule PairingsEngine.Tools.SessionTest do
  # async: true - pure ETS, no database. The store under test is the app's
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

  describe "memory budget" do
    # This store backs an unauthenticated upload page, so the cap has to be in
    # bytes, not just in rows: 500 entries of ten 5 MB uploads each would
    # otherwise pin gigabytes for an hour. The budget is shrunk here rather
    # than allocating real hundreds of megabytes, and every token these tests
    # create is removed again - the ETS table outlives the test.
    setup do
      Application.put_env(:pairings_engine, :tools_session_max_bytes, 300_000)

      on_exit(fn ->
        Application.delete_env(:pairings_engine, :tools_session_max_bytes)
        :ets.delete_all_objects(Session)
      end)

      :ok
    end

    test "a flood of large entries evicts the oldest and keeps total size bounded" do
      blob = :binary.copy(<<0>>, 100_000)

      tokens =
        for _ <- 1..6 do
          token = Session.put(Session.token(), %{blob: blob})
          # Distinct expiry stamps, so "oldest first" is unambiguous rather
          # than depending on how ETS happens to order same-millisecond rows.
          Process.sleep(2)
          token
        end

      total = :ets.foldl(fn {_t, _d, _e, bytes}, acc -> acc + bytes end, 0, Session)

      assert total <= 300_000

      # The most recent upload always survives - it is the one whose download
      # link the person is about to click.
      assert {:ok, %{blob: _}} = Session.get(List.last(tokens))
      # ...and the oldest ones are what paid for it.
      assert Session.get(List.first(tokens)) == :error
    end

    test "a single entry larger than the whole budget is still readable" do
      token = Session.put(Session.token(), %{blob: :binary.copy(<<0>>, 900_000)})

      assert {:ok, %{blob: _}} = Session.get(token)
    end
  end

  describe "what a write costs" do
    # Enforcing the cap used to read the WHOLE store into the writing
    # process - `:ets.foldl` to total the bytes, `:ets.tab2list` to order the
    # eviction - so one upload cost a copy of every other upload currently
    # held. The page needs no account, so N connections meant N such copies
    # alive at once, which is the store's own ceiling times however many
    # connections somebody cares to open. The cap itself is unchanged; this
    # is about what enforcing it costs, so it is measured rather than
    # asserted.
    setup do
      on_exit(fn ->
        Application.delete_env(:pairings_engine, :tools_session_max_bytes)
        :ets.delete_all_objects(Session)
      end)

      :ok
    end

    test "a write does not copy the whole store into the writer's heap" do
      # A list, not a binary: a large binary is reference-counted and shared
      # rather than copied, so it would not weigh what actually hurt here.
      # Ten of these is roughly 24 MB of term.
      big = Enum.to_list(1..150_000)

      for _ <- 1..10, do: Session.put(Session.token(), %{rows: big})

      # Under the byte budget, so this write takes the eviction path too -
      # the more expensive of the two reads.
      Application.put_env(:pairings_engine, :tools_session_max_bytes, 1)

      assert writes_within_heap?(2_000_000)
    end

    # One `put/3`, run in a process that may not grow past `bytes` - far
    # smaller than the store it is writing into. Copying that store in
    # exceeds the limit and the VM kills the process, so "did the write
    # survive" is the measurement.
    defp writes_within_heap?(bytes) do
      words = div(bytes, :erlang.system_info(:wordsize))

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: false})
          Session.put(Session.token(), %{v: 1})
        end)

      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> reason == :normal
      after
        5_000 -> flunk("the write never finished")
      end
    end
  end
end
