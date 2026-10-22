defmodule Mix.Tasks.Contracts.Check do
  @shortdoc "Fails if a vendored contract differs from its provider's"

  @moduledoc """
  Fetches every contract in `priv/contracts/vendor/contracts.json` exactly as
  `mix contracts.sync` would, writes nothing, and fails with a list of what
  differs: files the provider added, files it removed, files that changed,
  and `index.json` itself.

      mix contracts.check

  CI runs it on every push and pull request and once a day, because the
  provider can change its half of the interface on a day this repository
  has no commits at all - which is precisely the day nobody would look.
  When it fails: `mix contracts.sync`, then the tests, then fix whatever
  they find.
  """
  use Mix.Task

  alias Mix.Tasks.Contracts.Sync

  @impl Mix.Task
  def run(_args) do
    drift =
      for contract <- Sync.contracts(),
          line <- differences(contract),
          do: "  #{Sync.label(contract)}: #{line}"

    if drift == [] do
      Mix.shell().info("Vendored contracts match their providers.")
    else
      Mix.raise("""
      Vendored contracts differ from their providers:

      #{Enum.join(drift, "\n")}

      Run `mix contracts.sync`, then the tests.
      """)
    end
  end

  defp differences(contract) do
    {index, remote} = Sync.fetch!(contract)
    dir = Sync.dir(contract)
    local = Sync.local_files(contract)
    names = remote |> Map.keys() |> Enum.sort()

    added = for name <- names -- local, do: "added #{name}"
    removed = for name <- local -- names, do: "removed #{name}"

    changed =
      for name <- names, name in local, read(dir, name) != remote[name], do: "changed #{name}"

    index_line = if read(dir, "index.json") == index, do: [], else: ["changed index.json"]

    index_line ++ added ++ removed ++ changed
  end

  defp read(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, bytes} -> bytes
      {:error, _} -> nil
    end
  end
end
