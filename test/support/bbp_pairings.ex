defmodule PairingsEngine.Test.BbpPairings do
  @moduledoc """
  Runs a TRF16 tournament through `bbpPairings` (© Bierema Boyz Programming,
  Apache-2.0, vendored in `priv/bbppairings/` - see that directory's
  `LICENSE.txt`), a second, independently-written Dutch-system pairing
  engine, standalone. Exists purely for the cross-program-agreement check
  (`test/pairings_engine/cross_program_test.exs`) described in
  `docs/fide-endorsement.md`: running the *same* TRF16 text OpenPairings
  hands Ainalrami through a second, unrelated implementation and diffing the
  resulting pairings is a much stronger correctness signal than anything a
  single-engine checker can give, since it can't share a bug with
  OpenPairings' own engine.

  Its `-p` pairing-output format is the TRF pairing programs' common one,
  read by `parse_pairs/1`: a count line, then one `"white black"`
  starting-rank pair per line (`0` = pairing-allocated bye).

  bbpPairings refuses to guess an unhistoried round's initial board-1 color
  ("BBP Pairings does not support random selection of the initial piece
  color" - its README) and errors out instead. `pair/2` appends an
  `XXC white1` line whenever the TRF has no per-round game columns yet,
  forcing a deterministic choice so a round-1 comparison isn't just diffing
  two arbitrary-but-different color assignments. Rounds 2+ already carry
  real color history in the TRF, so this never applies past round 1.
  """

  @doc "Absolute path to this OS's vendored bbpPairings binary, or `nil` if this OS has none vendored."
  def binary_path do
    case os_binary_name() do
      nil -> nil
      name -> Path.join([:code.priv_dir(:pairings_engine), "bbppairings", name])
    end
  end

  defp os_binary_name do
    case :os.type() do
      {:unix, :linux} -> "bbpPairings-linux"
      {:win32, _} -> "bbpPairings-windows.exe"
      # No macOS build in bbpPairings' own releases - see binary_path/0's doc.
      _ -> nil
    end
  end

  @doc """
  Whether a usable bbpPairings binary is vendored for the current OS - the gate `test_helper.exs` checks.

  Present is not enough: the vendored Linux build is a 32-bit executable that
  needs a 32-bit C library with the `GLIBC_ABI_GNU_TLS` version, which GitHub's
  ubuntu-24.04 runner does not have (installing `libc6-i386` is not enough), so
  there it exists but cannot start. Run with no arguments it prints its banner
  and exits 0; anything else means it cannot run here.
  """
  def available? do
    case binary_path() do
      nil -> false
      path -> File.exists?(path) and runs?(path)
    end
  end

  defp runs?(path) do
    case System.cmd(path, [], stderr_to_stdout: true) do
      {out, 0} -> String.starts_with?(out, "BBP Pairings")
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Pairs `trf` (TRF16 text, same shape `PairingsEngine.Pairing.trf_input/5`
  builds) via bbpPairings' Dutch-system engine, returning
  `{:ok, [{white_rank, black_rank}, ...]}` (0 = pairing-allocated bye) or
  `{:error, reason}`.
  """
  def pair(trf) when is_binary(trf) do
    dir = workdir!()
    input = Path.join(dir, "input.trf")
    output = Path.join(dir, "output.txt")

    try do
      File.write!(input, with_forced_initial_color(trf))

      case System.cmd(binary_path(), ["--dutch", input, "-p", output], stderr_to_stdout: true) do
        {_out, 0} ->
          output |> File.read!() |> parse_pairs()

        {out, code} ->
          {:error, "bbpPairings failed (exit #{code}):\n#{out}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  # No "001 ... " row anywhere carries a round-1-or-later game column yet -
  # i.e. this is a fresh round-1 pairing - so bbpPairings has no history to
  # infer an initial color from and needs XXC forced explicitly. A TRF with
  # any prior round's results already has real color history, which both
  # engines read the same way, so this only ever fires for round 1.
  defp with_forced_initial_color(trf) do
    if trf =~ ~r/XXC\s/ or round_one?(trf) == false do
      trf
    else
      trf <> "XXC white1\r\n"
    end
  end

  # A player row's fixed-width game column starts right after the header
  # columns (position 92, 1-indexed, per Trf's own @player_cols) - presence
  # of ANY non-blank character there on ANY player row means real round
  # history already exists.
  defp round_one?(trf) do
    trf
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.starts_with?(&1, "001"))
    |> Enum.all?(fn line -> line |> String.slice(91..-1//1) |> String.trim() == "" end)
  end

  @doc """
  A TRF pairing program's `-p` output: first line the number of pairs, then
  `"white black"` per line as starting ranks, `0` the pairing-allocated bye.
  `{:error, message}` when the file is empty - a program that exits 0
  having written nothing has paired nothing.
  """
  def parse_pairs(text) do
    case text |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == "")) do
      [] ->
        {:error, "The pairing program produced no pairings output (an empty pairings file)"}

      [_count | lines] ->
        {:ok,
         Enum.map(lines, fn line ->
           [w, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
           {w, b}
         end)}
    end
  end

  # A randomized scratch directory, so concurrent runs never share a file.
  defp workdir! do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "bbppairings-#{suffix}")
    File.mkdir_p!(dir)
    dir
  end
end
