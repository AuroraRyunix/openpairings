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

  Every enrolment also carries a `level` - what the code may do, not just
  where it may do it:

    * `"helper"` - may fill a board that is currently blank, on the latest
      paired round only, and may never correct a result that is already
      there. The default for anything minted from now on.
    * `"deputy"` - the original, unrestricted behaviour: any paired round,
      correction included.

  plus an optional `board_from`/`board_to` range (both `nil` means every
  board) that applies regardless of level. `permit_result/4` and
  `permit_round/3` are where those rules actually live - see their docs.
  """
  import Ecto.Query

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Pairing
  alias PairingsEngine.Mobile.Enrollment

  @default_ttl_hours 24

  # How many code/token draws one creation may take before it gives up - see
  # `insert_enrollment/2`.
  @code_attempts 5

  @levels ~w(helper deputy)

  @doc """
  Creates an active enrollment for `tournament_id`. Returns `{:ok, enrollment}`
  or `{:error, changeset}` (an invalid `:level` or board range) /
  `{:error, :archived | :handed_off}`.

  `opts`: `:label` (free text), `:ttl_hours` (default #{@default_ttl_hours}),
  `:level` (`"helper"` or `"deputy"`, default `"helper"`), `:board_from` /
  `:board_to` (optional positive integers, `board_from <= board_to` when
  both are given - `nil`/`nil` means every board).

  Refuses `{:error, :archived}` / `{:error, :handed_off}` for a tournament
  that has gone read-only. Minting was ungated for a long time, and the
  failure that followed was quiet and badly timed: the QR scanned, the phone
  loaded the round, the helper tapped a result, and only THEN did the write
  meet `Tournaments.ensure_writable/1` and bounce. The arbiter found out at
  the board, mid-round, from somebody else's phone. Refusing here is the
  same fact delivered while it can still be acted on.
  """
  def create_enrollment(tournament_id, opts \\ []) do
    with :ok <- Tournaments.ensure_writable(tournament_id) do
      ttl = Keyword.get(opts, :ttl_hours, @default_ttl_hours)

      expires_at =
        DateTime.utc_now() |> DateTime.add(ttl * 3600, :second) |> DateTime.truncate(:second)

      insert_enrollment(
        %{
          tournament_id: tournament_id,
          label: Keyword.get(opts, :label, "") || "",
          level: Keyword.get(opts, :level, "helper") || "helper",
          board_from: Keyword.get(opts, :board_from),
          board_to: Keyword.get(opts, :board_to),
          expires_at: expires_at
        },
        @code_attempts
      )
    end
  end

  # Uniqueness is the DATABASE's answer, not a read-then-insert's. The old
  # `gen_unique_code/1` queried for the code it had just drawn and inserted
  # it if nothing came back - which two callers could do at once, and which
  # gave up after twenty attempts and inserted a duplicate anyway. Now the
  # partial unique index (`20260902120000_unique_active_enrollment_code`)
  # decides, and a rejected draw is simply drawn again: no read per
  # creation, and no window in which two creations can agree.
  #
  # Attempts are bounded so a genuinely full code space fails loudly rather
  # than spinning. Eight digits is 90 million, so reaching the bound means
  # something is wrong that a retry will not fix.
  defp insert_enrollment(attrs, attempts_left) do
    changeset =
      %Enrollment{}
      |> Ecto.Changeset.change(Map.put(attrs, :token, gen_token()))
      |> Ecto.Changeset.put_change(:code, random_code() |> Integer.to_string())
      |> Ecto.Changeset.validate_inclusion(:level, @levels)
      |> validate_board_range()
      # NOT the index's own name. SQLite reports a unique violation as
      # "UNIQUE constraint failed: mobile_enrollments.code" with no index
      # named in it, and the adapter synthesises `<table>_<column>_index`
      # from that - so the constraint to declare here is the synthesised
      # name, whatever the index is actually called.
      |> Ecto.Changeset.unique_constraint(:code, name: :mobile_enrollments_code_index)
      |> Ecto.Changeset.unique_constraint(:token)

    with {:error, %Ecto.Changeset{errors: errors} = failed} <- Repo.insert(changeset) do
      # Only a clash on the two generated secrets is worth another draw;
      # anything else (a missing tournament, say) would fail identically
      # every time and is returned as it stands.
      if attempts_left > 1 and (errors[:code] || errors[:token]) do
        insert_enrollment(attrs, attempts_left - 1)
      else
        {:error, failed}
      end
    end
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

  Deliberately `Repo.all |> List.first`, newest first, rather than
  `Repo.one`. The partial unique index added in
  `20260902120000_unique_active_enrollment_code` means two active rows
  cannot share a code any more - but this is the read reached by the PUBLIC
  `POST /m` with nothing on the path to rescue it, and `Repo.one` answers a
  second row by RAISING. A lookup on an unauthenticated route should not be
  the thing that turns a database that has drifted into a 500; the newest
  matching grant is the right answer and is what the index guarantees is
  the only one.
  """
  def get_active_by_code(code) when is_binary(code) do
    normalized = String.replace(code, ~r/\D/, "")

    if normalized == "" do
      nil
    else
      Repo.all(
        from e in active_query(),
          where: e.code == ^normalized,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: 1
      )
      |> List.first()
    end
  end

  def get_active_by_code(_), do: nil

  @doc "Fetches an active enrollment by id, or nil - used to re-validate the session on each request."
  def get_active(id) do
    Repo.one(from e in active_query(), where: e.id == ^id)
  end

  @doc """
  Revokes an enrollment (idempotent). Returns `{:ok, enrollment}`.

  Broadcasts `{:mobile_enrollment_revoked, id}` on the tournament's topic so
  the phone finds out at once. Without it a revoked phone kept watching the
  round - `MobileResultsLive` reloads on every tournament change but only
  re-checked the enrollment when it tried to WRITE - so "revoke" looked like
  it had done nothing until the helper next tapped a result.

  Refused, like minting one, on a tournament that has gone read-only. This
  is the direction that looks safe to allow, and it is worth saying why it
  is not allowed anyway: a handed-off tournament's list of admitted phones
  belongs to the copy that is actually running the event, and editing it
  here produces a second, divergent answer to "who may enter results" for no
  gain - the credential is already inert, because every result write goes
  through the same gate the revocation would.
  """
  def revoke(%Enrollment{} = enrollment) do
    with :ok <- Tournaments.ensure_writable(enrollment.tournament_id),
         {:ok, revoked} <-
           enrollment
           |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
           |> Repo.update() do
      Phoenix.PubSub.broadcast(
        PairingsEngine.PubSub,
        Tournaments.tournament_topic(revoked.tournament_id),
        {:mobile_enrollment_revoked, revoked.id}
      )

      {:ok, revoked}
    end
  end

  @doc """
  Revokes an enrollment by id within `tournament_id` (owner action).
  `{:error, :not_found}` if there is no such row, and the same read-only
  refusals as `revoke/1`.
  """
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

  @doc """
  Whether `enrollment` may even LOAD round `round_number`, independent of any
  particular board - checked before the round is displayed
  (`MobileResultsLive`'s `select_round` event), not only when a result is
  written to it.

  A `"helper"` may only be on the latest paired round (`latest_round`, i.e.
  `PairingsEngine.Pairing.paired_rounds_count/1`) - earlier rounds are the
  arbiter's history to review, not a helper's to touch. A `"deputy"` may load
  any round, same as the original unrestricted behaviour.
  """
  @spec permit_round(Enrollment.t(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, :earlier_round}
  def permit_round(%Enrollment{level: "helper"}, round_number, latest_round)
      when round_number != latest_round,
      do: {:error, :earlier_round}

  def permit_round(%Enrollment{}, _round_number, _latest_round), do: :ok

  @doc """
  Whether `enrollment` may write a result to `pairing`, which is sitting in
  round `round_number` of a tournament whose most recently paired round is
  `latest_round`.

  Three checks, each one of the maintainer's three rules and not a
  generalised permission matrix a form could misconfigure:

    1. **Round** - delegates to `permit_round/3`. A stale round counts too:
       if a helper is looking at what USED to be the latest round and a new
       one has since been paired, this refuses exactly as it would have
       refused a deliberate switch to an earlier round - the round they are
       looking at is no longer the latest, regardless of how they got there.
    2. **Board range** - `board_in_range?/2`, both levels.
    3. **Fill-once** - a `"helper"` may set a result on `pairing` only while
       `pairing.result` is blank (`""`); a `"deputy"` may always correct one,
       which is today's original behaviour.

  Returns `:ok` or `{:error, reason}`; the caller (`MobileResultsLive`) maps
  `reason` to the flash message a helper actually sees.
  """
  @spec permit_result(Enrollment.t(), Pairing.t(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, :earlier_round | :board_out_of_range | :already_set}
  def permit_result(%Enrollment{} = enrollment, %Pairing{} = pairing, round_number, latest_round) do
    with :ok <- permit_round(enrollment, round_number, latest_round),
         :ok <- check_board_range(enrollment, pairing.board) do
      check_blank(enrollment, pairing)
    end
  end

  @doc """
  Whether `board` falls inside `enrollment`'s board range. `board_from` and
  `board_to` are independently optional (an open-ended "10 and up" or "up to
  10" range is valid, not just a closed one) and `nil`/`nil` means every
  board - the common case, and why this is a fast path rather than a
  0..infinity range construction.
  """
  @spec board_in_range?(Enrollment.t(), integer()) :: boolean()
  def board_in_range?(%Enrollment{board_from: nil, board_to: nil}, _board), do: true

  def board_in_range?(%Enrollment{board_from: from, board_to: to}, board) do
    (is_nil(from) or board >= from) and (is_nil(to) or board <= to)
  end

  # ---- internals ----

  defp check_board_range(enrollment, board) do
    if board_in_range?(enrollment, board), do: :ok, else: {:error, :board_out_of_range}
  end

  # Only a helper is fill-once; a deputy corrects, which is the point of the
  # level. `pairing.result` is `""` (never `nil` - see `Pairing`'s schema
  # default) for a blank board, so this is the one place that has to know
  # that convention rather than every caller re-deriving it.
  defp check_blank(%Enrollment{level: "helper"}, %Pairing{result: result})
       when result not in [nil, ""],
       do: {:error, :already_set}

  defp check_blank(%Enrollment{}, %Pairing{}), do: :ok

  # `validate_number/3` and `validate_change/3` both no-op on a `nil` value
  # (absent from `changeset.changes`, or explicitly set to `nil`) rather than
  # treating it as an error - exactly what "board_from/board_to are each
  # independently optional" needs, so an unset bound reaches neither check
  # below.
  defp validate_board_range(changeset) do
    changeset
    |> Ecto.Changeset.validate_number(:board_from, greater_than: 0)
    |> Ecto.Changeset.validate_number(:board_to, greater_than: 0)
    |> validate_board_order()
  end

  defp validate_board_order(changeset) do
    from = Ecto.Changeset.get_field(changeset, :board_from)
    to = Ecto.Changeset.get_field(changeset, :board_to)

    if from && to && from > to do
      Ecto.Changeset.add_error(
        changeset,
        :board_to,
        "must be greater than or equal to board_from"
      )
    else
      changeset
    end
  end

  defp active_query do
    now = DateTime.utc_now()
    from e in Enrollment, where: is_nil(e.revoked_at) and e.expires_at > ^now
  end

  defp gen_token, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

  # Uniform over 10_000_000..99_999_999 - an 8-digit code, unique among
  # un-revoked enrollments by the index, not by this function.
  #
  # Two properties matter, and the obvious `Enum.random(100_000..999_999)`
  # had neither. First, this is a bearer credential, so it comes from the
  # CSPRNG rather than `:rand`'s observable, seedable state. Second, `code`
  # is matched by `get_active_by_code/1` across EVERY tournament, so a guess
  # wins if it hits any live enrollment anywhere: with N active phones the
  # odds per attempt are N/space, not 1/space. Six digits left that far too
  # small once a few tournaments run at once; eight costs the arbiter's
  # helper two extra taps (and nothing at all on the QR path, which is the
  # normal route).
  #
  # Rejection sampling rather than a bare `rem/2`, which would make the low
  # end of the range fractionally likelier.
  @code_span 90_000_000
  @largest_unbiased div(4_294_967_296, @code_span) * @code_span

  defp random_code do
    case :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() do
      n when n < @largest_unbiased -> 10_000_000 + rem(n, @code_span)
      _ -> random_code()
    end
  end
end
