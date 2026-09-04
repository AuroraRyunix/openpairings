defmodule PairingsEngine.MetaTest do
  # async: false - shares the `meta` table with every other test that reads
  # or writes through it (Publishing, Notice, SwarPublish's version setting).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Meta

  test "get/1 is nil for a key that was never set" do
    assert Meta.get("meta_test_never_set") == nil
  end

  test "put/2 then get/1 round-trips" do
    Meta.put("meta_test_key", "hello")
    assert Meta.get("meta_test_key") == "hello"
  end

  test "put/2 on an existing key replaces the value rather than erroring" do
    Meta.put("meta_test_key", "first")
    Meta.put("meta_test_key", "second")

    assert Meta.get("meta_test_key") == "second"
  end

  test "delete/1 removes the key" do
    Meta.put("meta_test_key", "hello")
    Meta.delete("meta_test_key")

    assert Meta.get("meta_test_key") == nil
  end

  test "delete/1 on a key that was never set is a no-op, not an error" do
    assert Meta.delete("meta_test_never_set") == :ok
  end
end
