defmodule PairingsEngine.Mobile do
  @moduledoc """
  "Enrol a phone" for no-account mobile result entry.

  An arbiter (from the tournament) generates a `PairingsEngine.Mobile.Enrollment`
  - a `token` (in a QR code / URL) plus a short numeric `code`. A helper scans
  the QR or types the code on their phone; that browser then gets a
  result-entry-only session scoped to the tournament (see
  `PairingsEngineWeb.MobileEnroll` / `PairingsEngineWeb.MobileResultsLive`)
  until the enrollment expires or the arbiter revokes it. No account, no access
  to anything but entering results for that one tournament.
  """
  import Ecto.Query

  alias PairingsEngine.Repo
  alias PairingsEngine.Mobile.Enrollment

  @default_ttl_hours 24

  @doc """
  Creates an active enrollment for `tournament_id`. Returns `{:ok, enrollment}`.
  `opts`: `:label` (free text), `:ttl_hours` (default #{@default_ttl_hours}).
  """
  def create_enrollment(tournament_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_hours, @default_ttl_hours)

    expires_at =
      DateTime.utc_now() |> DateTime.add(ttl * 3600, :second) |> DateTime.truncate(:second)

    %Enrollment{
      tournament_id: tournament_id,
      token: gen_token(),
      code: gen_unique_code(),
      label: Keyword.get(opts, :label, "") || "",
      expires_at: expires_at
    }
    |> Repo.insert()
  end

  @doc "Active (non-revoked, non-expired) enrollments for a tournament, newest first."
  def list_enrollments(tournament_id) do
    Repo.all(
      from e in active_query(),
        where: e.tournament_id == ^tournament_id,
        order_by: [desc: e.inserted_at, desc: e.id]
    )
  end

  @doc "Fetches an active enrollment by its `token` (QR/URL secret), or nil."
  def get_active_by_token(token) when is_binary(token) do
    Repo.one(from e in active_query(), where: e.token == ^token)
  end

  def get_active_by_token(_), do: nil

  @doc """
  Fetches an active enrollment by its short numeric `code` (manual entry), or
  nil. Digits only; anything else is treated as no match.
  """
  def get_active_by_code(code) when is_binary(code) do
    normalized = String.replace(code, ~r/\D/, "")

    if normalized == "" do
      nil
    else
      Repo.one(from e in active_query(), where: e.code == ^normalized)
    end
  end

  def get_active_by_code(_), do: nil

  @doc "Fetches an active enrollment by id, or nil - used to re-validate the session on each request."
  def get_active(id) do
    Repo.one(from e in active_query(), where: e.id == ^id)
  end

  @doc "Revokes an enrollment (idempotent). Returns `{:ok, enrollment}`."
  def revoke(%Enrollment{} = enrollment) do
    enrollment
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "Revokes an enrollment by id within `tournament_id` (owner action). nil if not found."
  def revoke(tournament_id, id) do
    case Repo.get_by(Enrollment, id: id, tournament_id: tournament_id) do
      nil -> {:error, :not_found}
      enrollment -> revoke(enrollment)
    end
  end

  @doc "A QR-code SVG string encoding `data` (typically the enroll URL)."
  def qr_svg(data) do
    data
    |> EQRCode.encode()
    |> EQRCode.svg(width: 240, background_color: "#ffffff", color: "#111111")
  end

  # ---- internals ----

  defp active_query do
    now = DateTime.utc_now()
    from e in Enrollment, where: is_nil(e.revoked_at) and e.expires_at > ^now
  end

  defp gen_token, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

  # 8-digit code, unique among currently-active enrollments.
  #
  # Two properties matter here, and the obvious `Enum.random(100_000..999_999)`
  # had neither. First, this is a bearer credential, so it comes from the
  # CSPRNG rather than `:rand`'s observable, seedable state. Second, `code` is
  # matched by `get_active_by_code/1` across EVERY tournament, so a guess wins
  # if it hits any live enrollment anywhere: with N active phones the odds per
  # attempt are N/space, not 1/space. Six digits left that far too small once
  # a few tournaments run at once; eight costs the arbiter's helper two extra
  # taps (and nothing at all on the QR path, which is the normal route).
  defp gen_unique_code(attempts \\ 0) do
    code = random_code() |> Integer.to_string()

    cond do
      attempts > 20 -> code
      get_active_by_code(code) == nil -> code
      true -> gen_unique_code(attempts + 1)
    end
  end

  # Uniform over 10_000_000..99_999_999. Rejection sampling rather than a bare
  # `rem/2`, which would make the low end of the range fractionally likelier.
  @code_span 90_000_000
  @largest_unbiased div(4_294_967_296, @code_span) * @code_span

  defp random_code do
    case :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() do
      n when n < @largest_unbiased -> 10_000_000 + rem(n, @code_span)
      _ -> random_code()
    end
  end
end
