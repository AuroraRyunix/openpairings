defmodule PairingsEngine.Desktop.Registry do
  @moduledoc """
  The few registry operations `PairingsEngine.Desktop.UninstallEntries` needs,
  behind a set of **roots that are passed in, never assumed**.

  A root is a location name (`:hkcu`, `:hklm`, `:hklm32`, `:backup`) mapped
  to an absolute `:win32reg` key path. `real_roots/0` is the only place the
  real `Uninstall` keys are written down; tests build their roots under
  `HKEY_CURRENT_USER\\Software\\OpenPairingsTest\\<unique>`, so a test cannot
  reach a real uninstall entry even by mistake - it has no path to one.

  Values come back as a map of name to a string (`REG_SZ`), an integer
  (`REG_DWORD`), or `{:raw, binary}` for anything else (Velopack writes
  `EstimatedSize` as a `REG_QWORD`), and go back the same way.
  """

  @type roots :: %{optional(atom()) => String.t()}
  @type value :: String.t() | integer() | {:raw, binary()}

  @uninstall "\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"

  @doc "The real locations. Nothing else in the application names them."
  @spec real_roots() :: roots()
  def real_roots do
    %{
      hkcu: "\\hkey_current_user" <> @uninstall,
      hklm: "\\hkey_local_machine" <> @uninstall,
      hklm32:
        "\\hkey_local_machine\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
      # Where a removed entry's values are kept, so removing one can be
      # undone by hand. Under the publisher key the .msi already writes to
      # (`Software\\OpenPairings\\OpenPairingsApp.DesktopShortcut`).
      backup: "\\hkey_current_user\\Software\\OpenPairings\\RemovedUninstallEntries"
    }
  end

  @doc "Whether this machine has a registry at all."
  @spec available?() :: boolean()
  def available?, do: match?({:win32, _}, :os.type())

  @doc "The values of `root\\name`, or `:missing`."
  @spec read(roots(), atom(), String.t()) :: {:ok, %{String.t() => value()}} | :missing
  def read(roots, root, name) do
    with_handle([:read], fn h ->
      case :win32reg.change_key(h, path(roots, root, name)) do
        :ok ->
          {:ok, values} = :win32reg.values(h)
          {:ok, Map.new(values, fn {k, v} -> {to_string(k), decode(v)} end)}

        {:error, _} ->
          :missing
      end
    end)
  end

  @doc "Creates `root\\name` if needed and sets every value in `values`."
  @spec put(roots(), atom(), String.t(), %{String.t() => value()}) :: :ok | {:error, term()}
  def put(roots, root, name, values) do
    with_handle([:read, :write], fn h ->
      with :ok <- :win32reg.change_key_create(h, path(roots, root, name)) do
        Enum.reduce_while(values, :ok, fn {k, v}, :ok ->
          case :win32reg.set_value(h, String.to_charlist(k), encode(v)) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    end)
  end

  @doc "Deletes `root\\name` (which must have no subkeys). A missing key is `:ok`."
  @spec delete(roots(), atom(), String.t()) :: :ok | {:error, term()}
  def delete(roots, root, name) do
    with_handle([:read, :write], fn h ->
      case :win32reg.change_key(h, path(roots, root, name)) do
        :ok -> :win32reg.delete_key(h)
        {:error, :enoent} -> :ok
        error -> error
      end
    end)
  end

  defp path(roots, root, name) do
    base = Map.fetch!(roots, root)

    if String.contains?(name, "\\") or name in ["", ".", ".."] do
      raise ArgumentError, "not a single registry key name: #{inspect(name)}"
    end

    String.to_charlist(base <> "\\" <> name)
  end

  defp with_handle(mode, fun) do
    {:ok, h} = :win32reg.open(mode)

    try do
      fun.(h)
    after
      :win32reg.close(h)
    end
  end

  defp decode(v) when is_list(v), do: List.to_string(v)
  defp decode(v) when is_integer(v), do: v
  defp decode(v) when is_binary(v), do: {:raw, v}

  defp encode(v) when is_binary(v), do: String.to_charlist(v)
  defp encode(v) when is_integer(v), do: v
  defp encode({:raw, v}) when is_binary(v), do: v
end
