defmodule PairingsEngine.Updates.InstallKind do
  @moduledoc """
  Which of the three shapes this running copy was installed as, for the
  update notice's install action. See `rel/windows/build_installer.ps1`'s
  `.NOTES` for the two Windows install roots this project's own installer
  actually produces, and `docs/binaries.md`'s "Updates" section for what
  each notice says.

    * `:velopack_per_user` - `%LOCALAPPDATA%\\OpenPairingsApp`, Velopack's
      `Update.exe` beside it, and that directory is writable by whoever is
      running the process. Setup.exe and a per-user `.msi` both install
      here.
    * `:velopack_per_machine` - `Program Files\\OpenPairingsApp`, same
      `Update.exe`, not writable without elevation. Only a per-machine
      `.msi` install produces this.
    * `:other` - everything else: the portable zip, the single-file Burrito
      binary, macOS, Linux. No `Update.exe` exists to detect.

  ## Why this stops at detection

  Velopack's own supported mechanism for a non-.NET app to check for and
  apply an update is `velopack_libc` - a C ABI (`vpkc_*`), confirmed during
  this feature's implementation to link and run correctly against this
  project's own toolchain (`zig cc -target x86_64-windows-gnu`). That part
  is not the obstacle.

  What blocks going further is architectural, not a toolchain problem: the
  process that would have to make that call is the one Velopack's own
  `wait_exit_then_apply_updates` is designed around - the running `--mainExe`
  itself, `OpenPairings.exe` (`rel/windows/launcher.c`) - and the "Install
  and restart" click happens inside the Phoenix/LiveView process, which is a
  *child* of that launcher's job object, not the launcher itself. Making the
  launcher perform the apply on the browser's behalf needs a signal from the
  BEAM process to the separate native one, which nothing in this codebase
  has today, and inventing one now - with no second real release yet to
  update FROM, and no way to exercise a live Windows install end to end in
  this environment - is exactly the "poke at Velopack internals" this
  feature was asked not to do speculatively. So detection stops here, and
  the notice offers a link to the release page for all three kinds - see
  `PairingsEngine.Updates.notice_for_render/0`. A follow-up that wires a real
  "Install and restart" button belongs in `rel/windows/launcher.c`, once
  there is a second release to test it against.

  ## Detection is pure filesystem inspection - no Velopack library involved

  Only `RELEASE_ROOT` (set by the generated release script, including the
  one `OpenPairings.exe` starts - see `rel/windows/launcher.c`) and whether
  `Update.exe` sits beside its parent directory. This works out to `:other`
  on every non-Windows build without an OS check: neither macOS nor Linux
  ships a `current\\` folder or an `Update.exe`, so the shape alone answers
  it, and the same code path is exercised (and tested) on every platform
  this runs on.
  """

  @type kind :: :velopack_per_user | :velopack_per_machine | :other

  @doc """
  Which kind this running copy is.

  Tests substitute `Application.put_env(:pairings_engine,
  :updates_install_kind_override, kind)` rather than faking a filesystem
  layout and a release environment variable - see the moduledoc's "the right
  action for each install type (stub the detection)" in the feature's own
  test coverage.
  """
  @spec detect() :: kind()
  def detect do
    case Application.get_env(:pairings_engine, :updates_install_kind_override) do
      nil -> detect_real()
      override when override in [:velopack_per_user, :velopack_per_machine, :other] -> override
    end
  end

  defp detect_real do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         expanded = Path.expand(root),
         "current" <- Path.basename(expanded),
         install_root = Path.dirname(expanded),
         true <- File.exists?(Path.join(install_root, "Update.exe")) do
      if writable?(install_root), do: :velopack_per_user, else: :velopack_per_machine
    else
      _ -> :other
    end
  end

  # `File.chmod` is a documented no-op on Windows (see docs/binaries.md), so
  # the only honest way to answer "can this process write here" is to try -
  # exactly what a per-machine install's actual update attempt would hit.
  defp writable?(dir) do
    probe = Path.join(dir, ".openpairings-write-probe-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      {:error, _reason} ->
        false
    end
  end
end
