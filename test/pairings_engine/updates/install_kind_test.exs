defmodule PairingsEngine.Updates.InstallKindTest do
  @moduledoc """
  Which of the three install shapes a running copy is detected as.

  The override is the primary seam - see the moduledoc on `detect/0` - and
  is what `PairingsEngineWeb.UpdateNoticeTest` uses to exercise "the right
  action for each install type" without a real Windows install. The tests
  below exercise the real filesystem probe directly, on whatever OS this
  suite happens to run on - see `PairingsEngine.Updates.InstallKind`'s
  moduledoc for why that probe needs no OS check to be correct everywhere.
  """
  use ExUnit.Case, async: false

  alias PairingsEngine.Updates.InstallKind

  setup do
    previous = System.get_env("RELEASE_ROOT")
    on_exit(fn -> reset_env(previous) end)
    System.delete_env("RELEASE_ROOT")

    on_exit(fn -> Application.delete_env(:pairings_engine, :updates_install_kind_override) end)

    :ok
  end

  defp reset_env(nil), do: System.delete_env("RELEASE_ROOT")
  defp reset_env(value), do: System.put_env("RELEASE_ROOT", value)

  describe "the override" do
    test "wins over any real detection" do
      for kind <- [:velopack_per_user, :velopack_per_machine, :other] do
        Application.put_env(:pairings_engine, :updates_install_kind_override, kind)
        assert InstallKind.detect() == kind
      end
    end
  end

  describe "real detection" do
    test "is :other with no RELEASE_ROOT set at all" do
      assert InstallKind.detect() == :other
    end

    test "is :other when RELEASE_ROOT is not inside a \"current\" folder" do
      dir = tmp_dir("not_current")
      System.put_env("RELEASE_ROOT", dir)

      assert InstallKind.detect() == :other
    end

    test "is :other when \"current\"'s parent has no Update.exe beside it" do
      root = tmp_dir("no_update_exe")
      current = Path.join(root, "current")
      File.mkdir_p!(current)
      System.put_env("RELEASE_ROOT", current)

      assert InstallKind.detect() == :other
    end

    test "is :velopack_per_user when Update.exe sits beside a writable install root" do
      root = tmp_dir("writable_install")
      current = Path.join(root, "current")
      File.mkdir_p!(current)
      File.write!(Path.join(root, "Update.exe"), "")
      System.put_env("RELEASE_ROOT", current)

      assert InstallKind.detect() == :velopack_per_user
    end
  end

  defp tmp_dir(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "openpairings_install_kind_test_#{name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
