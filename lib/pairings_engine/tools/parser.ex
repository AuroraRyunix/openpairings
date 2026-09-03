defmodule PairingsEngine.Tools.Parser do
  @moduledoc """
  Dispatches an uploaded file (from the public arbiter tools page, see
  docs/tools.md) to `PairingsEngine.Federations.BEL.SwarImport.build_structs/1` or
  `PairingsEngine.TrfImport.build_structs/1` - the pure, no-`Repo` builders
  each importer already exposes - based on its filename's extension.

  Neither `.swar` nor `.trf` has a registered/reliable browser MIME type (the
  same reason `PairingsEngineWeb.TournamentsLive`'s own SWAR/TRF upload
  inputs use `accept: :any`), so this only ever looks at the filename, and
  falls back to trying both parsers - SWAR first, then TRF - for an unknown
  or missing extension, so a file that lost its extension along the way (or
  was renamed) still has a chance to import.

  Pure and side-effect-free: never touches the database or the filesystem,
  never raises (both builders already guarantee that for arbitrary/hostile
  input - see their own moduledocs).
  """

  alias PairingsEngine.TrfImport
  alias PairingsEngine.Federations.BEL.SwarImport

  @doc """
  Parses `content` (a file's raw bytes) using `filename`'s extension to pick
  the importer. Returns `{:ok, {%Tournament{}, [%Player{}]}}` or
  `{:error, message}` with a single user-facing string.
  """
  def parse(filename, content) when is_binary(filename) and is_binary(content) do
    case detect_format(filename, content) do
      :swar -> via_swar(content)
      :trf -> via_trf(content)
      :unknown -> via_either(content)
    end
  end

  @doc """
  Which importer `content` is for: `:swar`, `:trf`, or `:unknown`.

  Decided by **content first**, with `filename`'s extension as a tiebreak
  only when the bytes are inconclusive. That order matters wherever a user
  picks the importer by hand: neither `.swar` nor `.trf` has a registered
  browser MIME type, so every upload input for them has to accept `:any`,
  and a file can always land in the "wrong" one. Sniffing means it still
  imports, instead of failing with a true-but-useless complaint from the
  importer it was handed to (a `.swar` fed to TRF reports "no 001 lines" -
  correct, and no help at all).
  """
  def detect_format(filename, content) when is_binary(filename) and is_binary(content) do
    cond do
      swar_binary?(content) -> :swar
      trf_text?(content) -> :trf
      true -> extension(filename)
    end
  end

  # A `.swar` opens with its own version string, serialized the way every
  # string in that format is: a little-endian int32 byte count followed by
  # that many bytes - `"v7.04"`, `"v6.78"`. Anchored at offset 0 and shaped
  # tightly enough that text can't collide with it (a leading `"001"` line
  # would read as a length of 0x31303030).
  defp swar_binary?(<<len::little-signed-32, rest::binary>>) when len in 3..16 do
    case rest do
      <<version::binary-size(^len), _::binary>> -> Regex.match?(~r/^v\d+\.\d+$/, version)
      _ -> false
    end
  end

  defp swar_binary?(_), do: false

  # TRF16 is line-oriented text whose player records are `001` lines - the
  # same thing `TrfImport` itself keys on. Guarded by `String.valid?/1` so a
  # binary that happens to contain those bytes can't match.
  defp trf_text?(content) do
    String.valid?(content) and Regex.match?(~r/^001[ \t]/m, content)
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

  # SwarImport has no error_message/1 helper of its own (unlike TrfImport) -
  # its `build_structs/1` only ever fails with `{:parse_failed, message}` or
  # a plain string (see its `parse/1` moduledoc), so this mirrors
  # `TrfImport.error_message/1`'s formatting for those same shapes.
  defp swar_error_message({:parse_failed, message}), do: message
  defp swar_error_message(reason) when is_binary(reason), do: reason
  defp swar_error_message(reason), do: inspect(reason)
end
