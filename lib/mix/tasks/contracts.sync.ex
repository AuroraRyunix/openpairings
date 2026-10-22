defmodule Mix.Tasks.Contracts.Sync do
  @shortdoc "Re-vendors the contracts OpenPairings consumes from their providers"

  @moduledoc """
  Rewrites `priv/contracts/vendor/<repo>/<name>/` from the provider's main
  branch, byte for byte: `index.json` first, then every file it lists, and
  any vendored file it no longer lists is deleted.

      mix contracts.sync

  Which contracts are vendored is `priv/contracts/vendor/contracts.json`, and
  nowhere else: `[{"repo": "openresults", "name": "publish-v1"}]`. The
  provider owns the contract; this copy exists so the offline tests can hold
  OpenPairings to it, and `mix contracts.check` (CI, daily) says when the
  provider has moved on without us.

  Run it when the check goes red, then run the tests - a sync that turns
  them red is the point, not an accident.

  HTTP is Req, already a dependency. Nothing here runs in `mix test`.
  """
  use Mix.Task

  @root "priv/contracts/vendor"
  @base "https://raw.githubusercontent.com/teapot-chess"

  # A provider's index names files; a name that could climb out of the
  # vendored directory is a broken (or hostile) index, refused before
  # anything is written.
  @file_name ~r/\A(?:examples\/)?[A-Za-z0-9][A-Za-z0-9_.-]*\.json\z/

  @impl Mix.Task
  def run(_args) do
    for contract <- contracts() do
      {index, files} = fetch!(contract)
      dir = dir(contract)
      stale = local_files(contract) -- Map.keys(files)

      File.mkdir_p!(dir)
      Enum.each(stale, &File.rm!(Path.join(dir, &1)))

      for {name, bytes} <- files do
        path = Path.join(dir, name)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end

      File.write!(Path.join(dir, "index.json"), index)

      Mix.shell().info(
        "#{label(contract)}: #{map_size(files)} files" <>
          if(stale == [], do: "", else: ", removed #{Enum.join(stale, ", ")}")
      )
    end

    :ok
  end

  @doc false
  # `[%{"repo" => ..., "name" => ...}]`, from the one list.
  def contracts do
    @root |> Path.join("contracts.json") |> File.read!() |> Jason.decode!()
  end

  @doc false
  def dir(%{"repo" => repo, "name" => name}),
    do: Path.join([@root, String.downcase(repo), name])

  @doc false
  def label(%{"repo" => repo, "name" => name}), do: "#{repo}/#{name}"

  @doc false
  # The provider's `index.json` as bytes, and `%{file => bytes}` for every
  # file it lists.
  def fetch!(%{"repo" => repo, "name" => name} = contract) do
    {:ok, _} = Application.ensure_all_started(:req)
    base = "#{@base}/#{repo}/main/priv/contracts/#{name}/"
    index = get!(base <> "index.json")

    listed =
      case Jason.decode(index) do
        {:ok, %{"files" => files}} when is_list(files) -> files
        _ -> Mix.raise("#{label(contract)}: index.json has no file list")
      end

    for file <- listed, not (is_binary(file) and file =~ @file_name) do
      Mix.raise("#{label(contract)}: index.json lists #{inspect(file)}, which is not a file name")
    end

    {index, Map.new(listed, &{&1, get!(base <> &1)})}
  end

  @doc false
  # Every vendored file but `index.json`, relative to the contract's directory.
  def local_files(contract) do
    dir = dir(contract)

    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.reject(&(&1 == "index.json"))
    |> Enum.sort()
  end

  # Bytes, undecoded: the copy has to be identical, not equivalent.
  defp get!(url) do
    case Req.get(url, decode_body: false, retry: :transient, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> body
      {:ok, %Req.Response{status: status}} -> Mix.raise("#{url} answered #{status}")
      {:error, error} -> Mix.raise("#{url}: #{Exception.message(error)}")
    end
  end
end
