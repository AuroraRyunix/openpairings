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

  One code, one device: the first phone to reach either entry path CLAIMS
  the enrollment (`claim/1`); every later phone presenting the same token or
  code is refused, not handed a session of its own. Without that, a printed
  QR left on a table is a working credential for anyone who walks past, and
  `label` below is the only way an audit entry distinguishes phones sharing
  one code - which stops being true the moment there is only ever one.

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

  alias PairingsEngine.Authz
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
    user_id = Keyword.get(opts, :user_id)

    with :ok <- ensure_reachable(),
         :ok <- Tournaments.ensure_writable(tournament_id),
         :ok <- ensure_holder(user_id, tournament_id) do
      ttl = Keyword.get(opts, :ttl_hours, @default_ttl_hours)

      expires_at =
        DateTime.utc_now() |> DateTime.add(ttl * 3600, :second) |> DateTime.truncate(:second)

      insert_enrollment(
        %{
          tournament_id: tournament_id,
          label: Keyword.get(opts, :label, "") || "",
          # An account's own code corrects like a deputy: the account is an
          # arbiter (or more) on this tournament, which is the point.
          level: if(user_id, do: "deputy", else: Keyword.get(opts, :level, "helper") || "helper"),
          user_id: user_id,
          board_from: Keyword.get(opts, :board_from),
          board_to: Keyword.get(opts, :board_to),
          expires_at: expires_at
        },
        @code_attempts
      )
    end
  end

  @doc """
  `create_enrollment/2` on behalf of `scope`'s account, counted against that
  account's hourly allowance of new codes (`PairingsEngine.RateLimit`'s
  `:mobile_code_create`). `{:error, :too_many_codes}` past it.

  Every active code is another right answer somewhere in the eight-digit
  space `/m` lets strangers guess at, so an account minting codes on a loop
  would be doing the guessing for whoever is guessing. The page mints
  through here; `create_enrollment/2` stays for callers that are not a
  person.
  """
  def create_enrollment_for(scope, tournament_id, opts \\ [])

  def create_enrollment_for(%{user: %{id: user_id}}, tournament_id, opts) do
    key = Integer.to_string(user_id)

    if PairingsEngine.RateLimit.allow?(:mobile_code_create, key) do
      with {:ok, _enrollment} = ok <- create_enrollment(tournament_id, opts) do
        PairingsEngine.RateLimit.record(:mobile_code_create, key)
        ok
      end
    else
      {:error, :too_many_codes}
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

  @doc """
  Whether any phone code is active anywhere - what keeps the phones' network
  listener open on a desktop copy (`PairingsEngineWeb.PhoneLan`).
  """
  def any_active?, do: Repo.exists?(active_query())

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
    Repo.one(from e in active_query(), where: e.token == ^token) |> held()
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
      |> held()
    end
  end

  def get_active_by_code(_), do: nil

  @doc """
  Fetches an active enrollment by id, or nil - used to re-validate the
  session on each request. A code that belongs to an account is active only
  while that account may still work in the tournament's hall
  (`Tournaments.hall_role/2`): an arbiter taken off the tournament loses
  their phone with it, whatever the code's own expiry says.
  """
  def get_active(id) do
    Repo.one(from e in active_query(), where: e.id == ^id) |> held()
  end

  defp held(%Enrollment{user_id: nil} = enrollment), do: enrollment

  defp held(%Enrollment{user_id: user_id, tournament_id: tid} = enrollment) do
    if Tournaments.hall_role(user_id, tid), do: enrollment
  end

  defp held(nil), do: nil

  # Minting a code for an account the tournament does not know would be a
  # way to put somebody's name on a phone they never held.
  defp ensure_holder(nil, _tournament_id), do: :ok

  defp ensure_holder(user_id, tournament_id) do
    if Tournaments.hall_role(user_id, tournament_id), do: :ok, else: {:error, :not_authorized}
  end

  @doc """
  Revokes every active code `user_id` holds on `tournament_id` - the account
  was taken off the tournament, or left it. Unlike `revoke/1` this does not
  ask whether the tournament is writable: taking access away is never the
  wrong direction, and `get_active/1` refuses those codes already anyway.
  """
  def revoke_for_user(_tournament_id, nil), do: :ok

  def revoke_for_user(tournament_id, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ids =
      Repo.all(
        from e in active_query(),
          where: e.tournament_id == ^tournament_id and e.user_id == ^user_id,
          select: e.id
      )

    Repo.update_all(from(e in Enrollment, where: e.id in ^ids), set: [revoked_at: now])

    for id <- ids do
      Phoenix.PubSub.broadcast(
        PairingsEngine.PubSub,
        Tournaments.tournament_topic(tournament_id),
        {:mobile_enrollment_revoked, id}
      )
    end

    :ok
  end

  @doc """
  Claims `enrollment` for the phone calling right now. Returns
  `{:ok, claimed}` for the first caller, `{:error, :already_claimed}` for
  every caller after that - including a retry by the very phone that just
  won, which is indistinguishable from a second phone at this layer and
  does not need to be told apart from one.

  The WHERE clause is the one thing deciding who wins, not this function's
  Elixir - the same shape of problem `PairingsEngine.Publishing.ensure_key/1`
  solves, and this follows its pattern for the same reason. A
  read-then-write (load the row, check `claimed_at` in an `if`, then write)
  lets two phones that scan the same QR within the same instant both read
  "unclaimed" before either has written, and both go on to win - the check
  and the write are two separate statements with a gap between them big
  enough for a second process to land in. An `update_all` guarded by
  `is_nil(claimed_at)` has no such gap: it is one statement, so the database
  serialises the two attempts, and only the one that actually flips
  `claimed_at` from null reports a row changed.

  Unlike `ensure_key/1`, the winner does not need to read the row back
  afterward. `ensure_key/1` re-reads because the value racing callers each
  generate (a random key) differs between them, so the loser needs to learn
  what the WINNER actually wrote. Here the value is `DateTime.utc_now/0` at
  the moment of the call - not drawn independently per racer in any way
  that matters to the caller - so the count from `update_all/2` already says
  everything the caller needs: 1 means the timestamp just written is this
  struct's, 0 means some other write got there first and this one changed
  nothing.
  """
  @spec claim(Enrollment.t()) :: {:ok, Enrollment.t()} | {:error, :already_claimed}
  def claim(%Enrollment{id: id} = enrollment) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(e in Enrollment, where: e.id == ^id and is_nil(e.claimed_at)),
        set: [claimed_at: now]
      )

    case count do
      1 -> {:ok, %{enrollment | claimed_at: now}}
      0 -> {:error, :already_claimed}
    end
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
  The topic the hall view's phones of `tournament_id` listen on - its own,
  not the tournament's, because every desk page follows that one and a
  LiveView with no clause for a message crashes on it.
  """
  def hall_topic(tournament_id), do: "hall:#{tournament_id}"

  @doc """
  Two entries disagreed about a board: `enrollment`'s said `entered`, the
  board already held `current`, put there by someone else since this phone
  last saw it. Refused, never overwritten (`Mobile.Sync`'s
  compare-and-set) - and told to every phone in the hall, so the one whose
  result stands sees it too, and the two arbiters find each other before
  either touches the board again.
  """
  def announce_conflict(%Enrollment{} = enrollment, pairing_id, board, entered, current) do
    Phoenix.PubSub.broadcast(
      PairingsEngine.PubSub,
      hall_topic(enrollment.tournament_id),
      {:hall_conflict,
       %{
         pairing_id: pairing_id,
         board: board,
         entered: entered,
         current: current || "",
         from: enrollment.label || "",
         enrollment_id: enrollment.id
       }}
    )
  end

  @lan_key "phone_lan_enabled"

  @doc """
  Whether the arbiter switched on "Let phones on this network connect" on
  this desktop copy (`PairingsEngineWeb.PhoneLan`). Always false on a
  hosted server, which has no such switch.
  """
  def lan_enabled?, do: Authz.local_mode?() and PairingsEngine.Meta.get(@lan_key) == "1"

  @doc false
  def lan_key, do: @lan_key

  # Phone enrolment used to be hosted-only, and this is where that is
  # decided - not the hidden panel on the Live Round page. It still is,
  # unless the arbiter of a desktop copy has switched on the phones'
  # network listener (`PairingsEngineWeb.PhoneLan`), which serves `/m` and
  # nothing else to the hall's private network.
  #
  # A local run binds to loopback, so no phone could reach it anyway and the
  # panel is replaced by a line saying so. But hiding a control is not the
  # same as refusing the action behind it: this codebase's own rule, written
  # into `PairingsEngineWeb.FideLive`, is that a control absent from the page
  # is still an event anybody can send. Minting was reachable that way.
  #
  # It matters more than the loopback bind makes it look. The day a local run
  # gains any way to answer another machine - an explicit listen address, a
  # tunnel, someone's reverse proxy - it has no accounts at all, and an
  # enrolment token would be the one credential that works from off the box.
  # Refusing here means that day cannot arrive by accident - and the day it
  # arrives on purpose, it is a switch the arbiter turned on, a listener that
  # answers `/m` alone, and codes that stop reaching anything when it is
  # turned off again.
  defp ensure_reachable do
    cond do
      not Authz.local_mode?() -> :ok
      lan_enabled?() -> :ok
      true -> {:error, :local_mode}
    end
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
       the board's STORED result is blank (`""`), whatever the caller's copy
       says; a `"deputy"` may always correct one, which is today's original
       behaviour.

  Returns `:ok` or `{:error, reason}`; the caller (`MobileResultsLive`) maps
  `reason` to the flash message a helper actually sees.
  """
  @spec permit_result(Enrollment.t(), Pairing.t(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, :earlier_round | :board_out_of_range | :already_set}
  def permit_result(%Enrollment{} = enrollment, %Pairing{} = pairing, round_number, latest_round) do
    with :ok <- permit_round(enrollment, round_number, latest_round),
         :ok <- check_board_range(enrollment, pairing.board) do
      check_blank(enrollment, stored(pairing))
    end
  end

  # The board as the database holds it now. Fill-once used to be asked of
  # the copy the phone's page was holding, which is blank for as long as the
  # page is behind: a helper could then write over the result the arbiter
  # had entered at the desk a moment earlier - the one thing a helper is not
  # allowed to do (audit 2026-10 part 2, G7). A pairing that was never saved
  # has no row to read and is taken as given.
  defp stored(%Pairing{id: nil} = pairing), do: pairing
  defp stored(%Pairing{id: id} = pairing), do: Repo.get(Pairing, id) || pairing

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

  @doc """
  Writes the audit row for a result `enrollment` just wrote to `pairing`
  (round `round_number`), `previous` being what the board held before.

  No-account phones went years without writing to the audit trail at all.
  Same action names as `PairingsEngineWeb.PairingsLive` uses, so the audit
  page's "pairings" filter and its descriptions pick these up unchanged;
  `Audit.log/4`'s `nil` user is "System", and the enrolment's id, code,
  label and level go into `details` so an arbiter can still tell which
  phone it was - and what that phone was allowed to do at the time.

  Shared by the direct tap (`PairingsEngineWeb.MobileResultsLive`) and the
  queued one (`PairingsEngine.Mobile.Sync`); `extra` adds what only the
  queued path knows (the phone's id for the entry).
  """
  def log_result(
        %Enrollment{} = enrollment,
        %Pairing{} = pairing,
        round_number,
        previous,
        result,
        extra \\ %{}
      ) do
    action =
      cond do
        result == "" -> "pairing.result_cleared"
        previous in [nil, ""] -> "pairing.result_entered"
        true -> "pairing.result_changed"
      end

    details =
      Map.merge(
        %{
          pairing_id: pairing.id,
          round: round_number,
          board: pairing.board,
          white: player_name(pairing.white_player),
          black: player_name(pairing.black_player),
          from: previous,
          to: result,
          via: "mobile",
          enrollment_id: enrollment.id,
          enrollment_code: enrollment.code,
          enrollment_label: enrollment.label,
          enrollment_level: enrollment.level
        },
        extra
      )

    # An account's own phone writes under that account; a no-account code
    # is "System", with the code in the details.
    PairingsEngine.Audit.log(enrollment.tournament_id, enrollment.user_id, action, details)
  end

  defp player_name(%PairingsEngine.Tournaments.Player{name: name}), do: name
  defp player_name(_), do: nil

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
