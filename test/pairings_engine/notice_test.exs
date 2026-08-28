defmodule PairingsEngine.NoticeTest do
  @moduledoc """
  The plain announcement banner.

  Most of what is worth testing here is what it is NOT: not a restart, not a
  countdown, and not something a server restart quietly loses.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Notice, Repo}

  setup do
    on_exit(&Notice.clear/0)
    Notice.clear()
    :ok
  end

  defp in_hours(h), do: DateTime.add(DateTime.utc_now(), round(h * 3600), :second)

  test "nothing is showing by default" do
    refute Notice.current()
  end

  test "a message shows until the time it was given" do
    {:ok, notice} = Notice.put("Big server maintenance in 12 hours.", in_hours(12))

    assert notice.message == "Big server maintenance in 12 hours."
    assert Notice.current().message == "Big server maintenance in 12 hours."
  end

  test "twelve hours is an ordinary horizon here" do
    # The deploy countdown caps at two hours, because a typo there leaves a
    # false promise about an imminent restart on every screen. This is an
    # announcement rather than a promise, so a long horizon is the point.
    {:ok, _} = Notice.put("We are pushing the new system tomorrow morning.", in_hours(12))
    assert Notice.current()
  end

  test "it disappears on its own once the time passes" do
    {:ok, _} = Notice.put("Maintenance soon.", in_hours(1))

    # Read as of two hours from now, without touching the stored row: an
    # expired notice and no notice have to mean the same thing to every
    # reader, so a server switched off across the expiry still does the right
    # thing when it comes back.
    refute Notice.current(in_hours(2))
    assert Notice.current()
  end

  test "a second announcement replaces the first" do
    {:ok, _} = Notice.put("First.", in_hours(4))
    {:ok, _} = Notice.put("Actually, second.", in_hours(4))

    # One banner, so one notice. A second announcement is a correction of
    # the first, not an addition to it.
    assert Notice.current().message == "Actually, second."
  end

  test "it can be taken down by hand" do
    {:ok, _} = Notice.put("Maintenance tonight.", in_hours(6))
    :ok = Notice.clear()
    refute Notice.current()
  end

  test "an empty message is refused" do
    assert {:error, message} = Notice.put("   ", in_hours(3))
    assert message =~ "empty"
    refute Notice.current()
  end

  test "a deadline in the past is refused" do
    assert {:error, message} = Notice.put("Too late.", in_hours(-1))
    assert message =~ "already passed"
    refute Notice.current()
  end

  test "it lives on disk, which is the whole difference from the deploy banner" do
    {:ok, _} = Notice.put("Big server maintenance in 12 hours.", in_hours(12))

    # `PairingsEngine.Deploy` holds its deadline in memory on purpose - a
    # pending restart is true only of the node about to be restarted, so
    # dying with that release is the feature. The opposite is true here: a
    # notice about maintenance twelve hours out has to outlive every restart
    # in those twelve hours, including the crash-restarts and the deploys of
    # unrelated fixes. A notice that quietly vanished at the first hiccup
    # would look exactly like one that was never set.
    #
    # So the test is that the row is really there, and that nothing is held
    # in a process that a restart would take with it.
    assert [[value]] = Repo.query!("SELECT value FROM meta WHERE key = 'site_notice'").rows
    assert value =~ "Big server maintenance in 12 hours."

    assert Process.whereis(PairingsEngine.Notice) == nil
  end

  test "subscribers are told when it changes" do
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Notice.topic())

    {:ok, _} = Notice.put("Maintenance tomorrow.", in_hours(20))
    assert_receive {:site_notice, %{message: "Maintenance tomorrow."}}

    :ok = Notice.clear()
    assert_receive {:site_notice, nil}
  end
end
