defmodule PairingsEngine.Tools.Parser do
  @moduledoc """
  Dispatches an uploaded file (from the public arbiter tools page, see
  docs/tools.md) to `PairingsEngine.SwarImport.build_structs/1` or
  `PairingsEngine.TrfImport.build_structs/1` — the pure, no-`Repo` builders
  each importer already exposes — based on its filename's extension.

  Neither `.swar` nor `.trf` has a registered/reliable browser MIME type (the
  same reason `PairingsEngineWeb.TournamentsLive`'s own SWAR/TRF upload
  inputs use `accept: :any`), so this only ever looks at the filename, and
  falls back to trying both parsers — SWAR first, then TRF — for an unknown
  or missing extension, so a file that lost its extension along the way (or
  was renamed) still has a chance to import.

  Pure and side-effect-free: never touches the database or the filesystem,
  never raises (both builders already guarantee that for arbitrary/hostile
  input — see their own moduledocs).
  """

  alias PairingsEngine.{SwarImport, TrfImport}

  @doc """
  Parses `content` (a file's raw bytes) using `filename`'s extension to pick
  the importer. Returns `{:ok, {%Tournament{}, [%Player{}]}}` or
  `{:error, message}` with a single user-facing string.
  """
  def parse(filename, content) when is_binary(filename) and is_binary(content) do
    case extension(filename) do
      :swar -> via_swar(content)
      :trf -> via_trf(content)
      :unknown -> via_either(content)
    end
  end

  defp extension(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".swar" -> :swar
      ".trf" -> :trf
      _ -> :unknown
    end
  end

  defp via_swar(content) do
    case SwarImport.build_structs(content) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, "Could not read this as a SWAR file: " <> swar_error_message(reason)}
    end
  end

  defp via_trf(content) do
    case TrfImport.build_structs(content) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, TrfImport.error_message(reason)}
    end
  end

  # Unknown extension: try SWAR first (its own parser fails fast on anything
  # that isn't its exact binary layout), then TRF; if both fail, report the
  # TRF error since TRF is the more common/plain-text format an arbiter is
  # likely to have renamed.
  defp via_either(content) do
    case SwarImport.build_structs(content) do
      {:ok, result} ->
        {:ok, result}

      {:error, _swar_reason} ->
        case TrfImport.build_structs(content) do
          {:ok, result} ->
            {:ok, result}

          {:error, trf_reason} ->
            {:error,
             "Could not read this file as either SWAR or TRF: " <>
               TrfImport.error_message(trf_reason)}
        end
    end
  end

  # SwarImport has no error_message/1 helper of its own (unlike TrfImport) —
  # its `build_structs/1` only ever fails with `{:parse_failed, message}` or
  # a plain string (see its `parse/1` moduledoc), so this mirrors
  # `TrfImport.error_message/1`'s formatting for those same shapes.
  defp swar_error_message({:parse_failed, message}), do: message
  defp swar_error_message(reason) when is_binary(reason), do: reason
  defp swar_error_message(reason), do: inspect(reason)
end
