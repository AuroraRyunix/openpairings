defmodule PairingsEngine.Manubrium do
  @moduledoc """
  Manubrium, the full app (docs/manubrium.md, "Full app"): the native phone
  app an arbiter runs a tournament from, against one or more servers at
  once. This module is its account side - connecting a phone, the devices
  an account has, and the phone code a device enters results under. What
  the app may DO is the API's (`PairingsEngineWeb.ManubriumApi`), which
  reaches every write through the same functions the desk pages use.

  ## The token model

    1. A signed-in account makes a **connect code** (`create_connect_code/2`):
       a 256-bit one-time secret, good for ten minutes, shown as a QR code
       carrying the server's address and the secret (`connect_link/2`). Only
       its hash is stored.
    2. The app trades it, once, for a **device token** (`redeem/3`): another
       256-bit secret, long-lived, bound to the account and to this one
       phone. Only its hash is stored, with the last four characters for
       telling phones apart. Refused trades are counted per client address
       (`PairingsEngine.RateLimit`'s `:manubrium_redeem`).
    3. Every API request carries the token as a bearer (`authenticate/1`).
       There is no cookie and no CSRF token: nothing here is a browser
       session.
    4. The account page lists the devices and withdraws any of them
       (`revoke_device/2`); the app can sign itself out (`revoke/1`).
       Withdrawn is final - the phone is refused from its next request on,
       and so is every phone code it held.

  A device has the account's rights, no more: the API asks
  `Tournaments.hall_role/2` and `Tournaments.get_authorized_tournament/2`
  on every request, so an arbiter taken off a tournament loses it on the
  phone at the same moment as everywhere else.

  ## Results go through the hall's queue

  A device enters results and incidents under an account-bound phone code
  of its own, one per tournament (`enrollment_for/2`), through
  `PairingsEngine.Mobile.Sync` - so the app's offline queue is judged
  exactly as the hall pages' is: idempotent client ids, compare-and-set,
  every refusal, the account's name in the audit trail. The code is
  claimed the moment it is made, so it can never be typed in at `/m`.
  """
  import Ecto.Query

  alias PairingsEngine.{Mobile, RateLimit, Repo, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Manubrium.{ConnectCode, Device}
  alias PairingsEngine.Mobile.Enrollment
  alias PairingsEngine.Tournaments.Pairing

  @connect_ttl_minutes 10
  # A device's phone code in one tournament. Renewed by `enrollment_for/2`
  # when it runs out, so this only bounds how long a forgotten one lingers
  # in the desk's list of phones.
  @enrollment_ttl_hours 24 * 14
  # How stale `last_used_at` may get before a request writes it again: the
  # account page says "last seen", not "last request", and a write per poll
  # would be a write every few seconds per phone.
  @touch_after_seconds 60

  @token_prefix "mnb_"

  @doc "How long a connect code is good for, in minutes."
  def connect_ttl_minutes, do: @connect_ttl_minutes

  ## ---------- connecting ----------

  @doc """
  Makes a connect code for `scope`'s account, for the app to reach this
  server at `base_url`. Returns `{:ok, %{secret:, link:, expires_at:}}` -
  the secret is in the link and nowhere else; it cannot be shown again.

  `{:error, :too_many}` past the account's hourly allowance,
  `{:error, :no_address}` without a base URL (a desktop copy whose phones'
  network listener is off).
  """
  def create_connect_code(%Scope{user: %User{} = user}, base_url) do
    key = Integer.to_string(user.id)

    cond do
      not (is_binary(base_url) and base_url != "") ->
        {:error, :no_address}

      not RateLimit.allow?(:manubrium_connect, key) ->
        {:error, :too_many}

      true ->
        RateLimit.record(:manubrium_connect, key)
        secret = secret()
        now = now()

        Repo.insert!(%ConnectCode{
          user_id: user.id,
          secret_hash: hash(secret),
          base_url: base_url,
          expires_at: DateTime.add(now, @connect_ttl_minutes * 60, :second)
        })

        {:ok,
         %{
           secret: secret,
           link: connect_link(base_url, secret),
           expires_at: DateTime.add(now, @connect_ttl_minutes * 60, :second)
         }}
    end
  end

  def create_connect_code(_scope, _base_url), do: {:error, :not_authorized}

  @doc """
  What the QR code carries: `manubrium://connect?server=<base_url>&secret=<secret>`.
  A custom scheme, so the phone's camera hands it to the app and never to a
  browser that would put the secret in somebody's history.
  """
  def connect_link(base_url, secret) do
    "manubrium://connect?" <> URI.encode_query(%{"server" => base_url, "secret" => secret})
  end

  @doc """
  Trades `secret` for a device token. `attrs` may carry `"name"` (what the
  phone calls itself, shown on the account page) and `"platform"`.
  `address` is the caller's client address, for the refusal budget.

  Returns `{:ok, device, token}` - the token exists only in this return
  value - or `{:error, :invalid}` (unknown, used or expired; one answer for
  all three), or `{:error, :rate_limited}`.

  The trade is one `UPDATE ... WHERE used_at IS NULL AND expires_at > now`:
  two phones scanning the same QR at the same instant cannot both win.
  """
  def redeem(secret, attrs, address) when is_binary(address) do
    if RateLimit.allow?(:manubrium_redeem, address) do
      case claim_code(secret) do
        {:ok, code} ->
          {:ok, device, token} = insert_device(code.user_id, attrs)
          {:ok, device, token}

        :error ->
          RateLimit.record(:manubrium_redeem, address)
          {:error, :invalid}
      end
    else
      {:error, :rate_limited}
    end
  end

  defp claim_code(secret) when is_binary(secret) and secret != "" do
    now = now()
    digest = hash(secret)

    case Repo.one(from c in ConnectCode, where: c.secret_hash == ^digest) do
      %ConnectCode{} = code ->
        {count, _} =
          Repo.update_all(
            from(c in ConnectCode,
              where: c.id == ^code.id and is_nil(c.used_at) and c.expires_at > ^now
            ),
            set: [used_at: now]
          )

        if count == 1 and user_exists?(code.user_id), do: {:ok, code}, else: :error

      nil ->
        :error
    end
  end

  defp claim_code(_secret), do: :error

  defp user_exists?(user_id), do: Repo.exists?(from u in User, where: u.id == ^user_id)

  defp insert_device(user_id, attrs) do
    token = @token_prefix <> secret()

    device =
      Repo.insert!(%Device{
        user_id: user_id,
        name: clip(attrs["name"], 60),
        platform: clip(attrs["platform"], 20),
        token_hash: hash(token),
        token_hint: String.slice(token, -4, 4),
        last_used_at: now()
      })

    {:ok, device, token}
  end

  defp clip(value, max) when is_binary(value),
    do: value |> String.replace(~r/[\x00-\x1F\x7F]/u, "") |> String.trim() |> String.slice(0, max)

  defp clip(_value, _max), do: ""

  ## ---------- every request ----------

  @doc """
  The live device `token` belongs to, with its account loaded, or `:error`
  for an unknown or withdrawn one. Notes when it was last heard from, at
  most once a minute.
  """
  def authenticate(@token_prefix <> _rest = token) do
    digest = hash(token)

    query =
      from d in Device,
        where: d.token_hash == ^digest and is_nil(d.revoked_at),
        preload: [:user]

    case Repo.one(query) do
      %Device{user: %User{}} = device -> {:ok, touch(device)}
      _ -> :error
    end
  end

  def authenticate(_token), do: :error

  defp touch(%Device{last_used_at: last} = device) do
    now = now()

    if is_nil(last) or DateTime.diff(now, last) >= @touch_after_seconds do
      Repo.update_all(from(d in Device, where: d.id == ^device.id), set: [last_used_at: now])
      %{device | last_used_at: now}
    else
      device
    end
  end

  @doc "The scope a device acts with: its account's, as a session would build it."
  def scope(%Device{user: %User{} = user}), do: Scope.for_user(user)

  ## ---------- the account's devices ----------

  @doc "The account's connected (not withdrawn) devices, most recently seen first."
  def list_devices(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from d in Device,
        where: d.user_id == ^user_id and is_nil(d.revoked_at),
        order_by: [desc_nulls_last: d.last_used_at, desc: d.id]
    )
  end

  def list_devices(_scope), do: []

  @doc """
  Withdraws device `id` of `scope`'s account. `{:ok, device}`, or
  `{:error, :not_found}` for a device that is not this account's (one
  answer for "no such device" and "somebody else's").
  """
  def revoke_device(%Scope{user: %User{id: user_id}}, id) do
    with {:ok, id} <- to_id(id),
         %Device{} = device <-
           Repo.one(
             from d in Device,
               where: d.id == ^id and d.user_id == ^user_id and is_nil(d.revoked_at)
           ) do
      revoke(device)
    else
      _ -> {:error, :not_found}
    end
  end

  def revoke_device(_scope, _id), do: {:error, :not_found}

  @doc "Withdraws `device` (signing out from the app does this). Idempotent."
  def revoke(%Device{} = device) do
    now = now()

    Repo.update_all(
      from(d in Device, where: d.id == ^device.id and is_nil(d.revoked_at)),
      set: [revoked_at: now]
    )

    :ok = Mobile.revoke_for_device(device.id)
    {:ok, %{device | revoked_at: device.revoked_at || now}}
  end

  @doc """
  Whether any device or unused connect code is live - what keeps a desktop
  copy's phones' network listener open (`PairingsEngineWeb.PhoneLan`),
  beside the phone codes.
  """
  def any_active? do
    now = now()

    Repo.exists?(from d in Device, where: is_nil(d.revoked_at)) or
      Repo.exists?(from c in ConnectCode, where: is_nil(c.used_at) and c.expires_at > ^now)
  end

  ## ---------- the phone code a device enters under ----------

  @doc """
  The account-bound, already-claimed phone code `device` enters results and
  incidents under in `tournament_id`, made on first use and again when it
  runs out. `{:ok, enrollment}`, or the refusals of
  `Mobile.create_enrollment/2`: `{:error, :not_authorized}` (the account
  is not on the tournament), `{:error, :archived | :handed_off}`,
  `{:error, :local_mode}` (a desktop copy with the phones' network
  listener off).
  """
  def enrollment_for(%Device{} = device, tournament_id) when is_integer(tournament_id) do
    case Mobile.get_active_for_device(device.id, tournament_id) do
      %Enrollment{} = enrollment ->
        {:ok, enrollment}

      nil ->
        with {:ok, enrollment} <-
               Mobile.create_enrollment(tournament_id,
                 user_id: device.user_id,
                 device_id: device.id,
                 label: label(device),
                 ttl_hours: @enrollment_ttl_hours
               ) do
          # Claimed at once: a device's code is never typed in anywhere,
          # and an unclaimed one would be a working answer at `/m` for as
          # long as it lived.
          Mobile.claim(enrollment)
        end
    end
  end

  defp label(%Device{name: name}) when name not in [nil, ""], do: "Manubrium: " <> name
  defp label(_device), do: "Manubrium app"

  ## ---------- clearing a result ----------

  @doc """
  Clears the result of pairing `pairing_id` in round `round_number`, for the
  device's code `enrollment` - the hall's clear (two taps on a phone,
  online only), never queued. `expected` is the result the phone showed:
  compare-and-set, as for every queued entry, so a clear never takes away
  a result the phone did not see.

  Every gate a deputy's clear meets in the hall: `Mobile.permit_result/4`,
  `Tournaments.result_clearable?/1` (archived, handed off, a closed
  FIDE-mode round, a result already sent, a match with a score) and
  `Tournaments.update_pairing_result/3`; then the audit row under the
  account (`Mobile.log_result/6`).

  `{:ok, pairing}`, `{:conflict, current}`, or `{:error, reason}`.
  """
  def clear_result(%Enrollment{} = enrollment, pairing_id, round_number, expected)
      when is_integer(pairing_id) and is_integer(round_number) do
    latest = PairingsEngine.Pairing.paired_rounds_count(enrollment.tournament_id)

    with %Pairing{} = pairing <- fetch_pairing(enrollment.tournament_id, pairing_id, round_number),
         :ok <- Mobile.permit_result(enrollment, pairing, round_number, latest),
         :ok <- same_result(pairing, expected),
         true <- pairing.result not in [nil, ""] || {:error, :already_blank},
         true <- Tournaments.result_clearable?(pairing) || {:error, :not_clearable},
         {:ok, cleared} <- Tournaments.update_pairing_result(pairing, "") do
      Mobile.log_result(enrollment, pairing, round_number, pairing.result, "", %{via_app: true})
      {:ok, cleared}
    else
      nil -> {:error, :board_gone}
      {:conflict, _current} = conflict -> conflict
      {:error, _reason} = error -> error
    end
  end

  defp fetch_pairing(tournament_id, pairing_id, round_number) do
    Repo.one(
      from p in Pairing,
        join: r in PairingsEngine.Tournaments.Round,
        on: r.id == p.round_id,
        where:
          p.id == ^pairing_id and r.tournament_id == ^tournament_id and r.number == ^round_number and
            not is_nil(p.black_player_id),
        preload: [:white_player, :black_player]
    )
  end

  defp same_result(%Pairing{result: stored}, expected) do
    if (stored || "") == (expected || ""), do: :ok, else: {:conflict, stored || ""}
  end

  ## ---------- helpers ----------

  @doc false
  def hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  defp secret, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp to_id(id) when is_integer(id), do: {:ok, id}

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp to_id(_id), do: :error
end
