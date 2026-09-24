defmodule PairingsEngine.Badges.Image do
  @moduledoc """
  Checks an uploaded or fetched badge image before it is stored.

  The type comes from the file's own signature, never from its name or the
  browser's content type - the same rule `PairingsEngine.Tournaments.set_logo/2`
  applies to the print logo, and through the same function. Raster only: SVG
  can carry script, and these bytes are served back into the app's pages.

  The pixel size is read from the image header, so a huge image is refused
  without decoding it. There is no resizing: the app has no image library,
  and a photo at print resolution for a 39 x 49 mm box is well under the limit.
  """

  alias PairingsEngine.Tournaments

  @limits %{
    photo: %{bytes: 1_000_000, pixels: 2400},
    logo: %{bytes: 1_000_000, pixels: 3000}
  }

  @doc "The byte and pixel limits for `kind` (`:photo` or `:logo`)."
  def limits(kind), do: Map.fetch!(@limits, kind)

  @doc """
  `{:ok, content_type}` for an acceptable image of `kind`, or
  `{:error, :invalid_image | :too_large | :too_many_pixels}`.
  """
  def validate(binary, kind) when is_binary(binary) do
    %{bytes: max_bytes, pixels: max_pixels} = limits(kind)

    with :ok <- check_size(binary, max_bytes),
         {:ok, type} <- detect(binary),
         :ok <- check_dimensions(binary, type, max_pixels) do
      {:ok, type}
    end
  end

  def validate(_binary, _kind), do: {:error, :invalid_image}

  defp check_size(binary, max) when byte_size(binary) > max, do: {:error, :too_large}
  defp check_size(_binary, _max), do: :ok

  defp detect(binary) do
    case Tournaments.detect_image_type(binary) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :invalid_image}
    end
  end

  defp check_dimensions(binary, type, max) do
    case dimensions(binary, type) do
      {w, h} when w > 0 and h > 0 and w <= max and h <= max -> :ok
      {w, h} when w > 0 and h > 0 -> {:error, :too_many_pixels}
      _ -> {:error, :invalid_image}
    end
  end

  @doc "`{width, height}` read from the header, or `nil` when it cannot be read."
  def dimensions(
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _len::32, "IHDR", w::32, h::32, _::binary>>,
        _
      ),
      do: {w, h}

  def dimensions(<<"GIF8", _v::binary-size(2), w::little-16, h::little-16, _::binary>>, _),
    do: {w, h}

  def dimensions(<<"RIFF", _::binary-size(4), "WEBP", chunk::binary>>, _), do: webp(chunk)
  def dimensions(<<0xFF, 0xD8, rest::binary>>, _), do: jpeg(rest)
  def dimensions(_binary, _type), do: nil

  # Lossy: the frame header's 14-bit sizes. Lossless: 14-bit sizes packed
  # after the 0x2F signature. Extended: 24-bit "minus one" sizes.
  defp webp(
         <<"VP8 ", _size::little-32, _frame::binary-size(3), 0x9D, 0x01, 0x2A, w::little-16,
           h::little-16, _::binary>>
       ),
       do: {Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF)}

  defp webp(<<"VP8L", _size::little-32, 0x2F, bits::little-32, _::binary>>),
    do: {Bitwise.band(bits, 0x3FFF) + 1, Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1}

  defp webp(
         <<"VP8X", _size::little-32, _flags::binary-size(4), w::little-24, h::little-24,
           _::binary>>
       ),
       do: {w + 1, h + 1}

  defp webp(_), do: nil

  # Walk the segments to the first start-of-frame marker (C0-CF except the
  # DHT/JPG/DAC markers C4, C8, CC), which carries height then width.
  defp jpeg(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {w, h}

  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9, do: jpeg(rest)

  defp jpeg(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_::binary-size(^skip), next::binary>> -> jpeg(next)
      _ -> nil
    end
  end

  defp jpeg(_), do: nil

  @doc "A `data:` URI for stored image bytes, or nil."
  def data_uri(nil, _type), do: nil
  def data_uri(_data, nil), do: nil
  def data_uri(data, type), do: "data:#{type};base64,#{Base.encode64(data)}"
end
