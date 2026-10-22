defmodule PairingsEngine.PlayerWarnings do
  @moduledoc """
  Player data that looks wrong, and says so without refusing anything.

  A rating of 9999, a birth year of 1823 or a federation of "Belgium" is
  usually a typo, occasionally true (a historic player, a federation the
  list does not know), and never a reason to lose the registration or abort
  an import of four hundred rows. So these checks live apart from the
  changeset: they return a list of what looks off, the Players page shows it
  next to the data, and nothing is rejected.

  Checks, each an atom:

    * `:rating` - any of the three ratings below 0 or above 3000
    * `:birth_year` - before 1900 or after the current year
    * `:federation` - present but not three letters
  """

  @max_rating 3000
  @min_year 1900

  @type warning :: :rating | :birth_year | :federation

  @doc "Warnings for form parameters (string keys, values as typed) or a struct."
  @spec check(map()) :: [warning()]
  def check(data) do
    Enum.filter([:rating, :birth_year, :federation], &flagged?(&1, data))
  end

  defp flagged?(:rating, data) do
    Enum.any?(~w(fide_rating national_rating tournament_rating), fn key ->
      case integer(field(data, key)) do
        nil -> false
        n -> n < 0 or n > @max_rating
      end
    end)
  end

  defp flagged?(:birth_year, data) do
    case integer(field(data, "birth_year")) do
      nil -> false
      0 -> false
      n -> n < @min_year or n > Date.utc_today().year
    end
  end

  defp flagged?(:federation, data) do
    case field(data, "federation") do
      v when is_binary(v) ->
        v = String.trim(v)
        v != "" and not Regex.match?(~r/\A[A-Za-z]{3}\z/, v)

      _ ->
        false
    end
  end

  defp field(%{__struct__: _} = struct, key), do: Map.get(struct, String.to_existing_atom(key))
  defp field(map, key) when is_map(map), do: Map.get(map, key)

  defp integer(n) when is_integer(n), do: n
  defp integer(n) when is_float(n), do: round(n)

  defp integer(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp integer(_), do: nil
end
