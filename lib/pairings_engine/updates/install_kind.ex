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

  ## Detection only - `:velopack_per_user` is what unlocks the button

  This module still only ever inspects the filesystem; it never touches
  `velopack_libc.dll` itself. What changed in 0.58.0 is what a
  `:velopack_per_user` result now permits elsewhere: the process that
  actually applies an update is `OpenPairings.exe`
  (`rel/windows/launcher.c`), the running `--mainExe` Velopack's own
  `vpkc_wait_exit_then_apply_updates` is designed around - never the
  Phoenix/LiveView process, which is only ever a *child* of that launcher's
  job object. The signal that crosses that boundary is a dedicated exit
  code the app shuts down with on confirmation
  (`PairingsEngine.Updates.request_install_and_restart/0`) and the launcher
  watches for on its child - see that file's "In-app updates" header
  section.

  `:velopack_per_machine` still only ever gets a link, on purpose, not as a
  gap to close later: an update there needs an administrator every time (see
  docs/binaries.md's "Per-machine installs cannot update without an admin
  prompt"), so offering a button that would only fail is worse than not
  offering one. `:other` has no `Update.exe` to apply anything with, same as
  before.

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
