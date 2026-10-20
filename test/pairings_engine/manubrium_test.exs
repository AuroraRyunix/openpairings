defmodule PairingsEngine.ManubriumTest do
  @moduledoc """
  The full app's account side (docs/manubrium.md, "Full app"): connect
  codes, device tokens, withdrawing them, and the phone code a device
  enters results under.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Manubrium, Mobile, RateLimit, Repo, Tournaments}
  alias PairingsEngine.Manubrium.{ConnectCode, Device}
  alias PairingsEngine.Mobile.Enrollment

  setup do
    RateLimit.clear_all()
    %{scope: user_scope_fixture()}
  end

  defp code(scope) do
    {:ok, code} = Manubrium.create_connect_code(scope, "https://pairings.example")
    code
  end

  defp device(scope) do
    %{secret: secret} = code(scope)
    {:ok, device, token} = Manubrium.redeem(secret, %{"name" => "Pixel"}, "10.0.0.9")
    {device, token}
  end

  describe "connect codes" do
    test "carry the server and the secret, and only the secret's hash is stored", %{scope: scope} do
      %{secret: secret, link: link, expires_at: expires_at} = code(scope)

      assert link =~ "manubrium://connect?"
      query = link |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query == %{"server" => "https://pairings.example", "secret" => secret}

      [stored] = Repo.all(ConnectCode)
      assert stored.secret_hash == Manubrium.hash(secret)
      refute stored.secret_hash == secret
      assert DateTime.diff(expires_at, DateTime.utc_now()) in 500..600
    end

    test "need an address, and run out per account", %{scope: scope} do
      assert Manubrium.create_connect_code(scope, nil) == {:error, :no_address}

      for _ <- 1..RateLimit.config(:manubrium_connect).max, do: code(scope)

      assert Manubrium.create_connect_code(scope, "https://x") == {:error, :too_many}
    end
  end

  describe "redeeming" do
    test "trades the code once for a token whose hash alone is kept", %{scope: scope} do
      %{secret: secret} = code(scope)

      assert {:ok, %Device{} = device, "mnb_" <> _ = token} =
               Manubrium.redeem(
                 secret,
                 %{"name" => "Pixel\n8", "platform" => "android"},
                 "10.0.0.1"
               )

      assert device.name == "Pixel8"
      assert device.platform == "android"
      assert device.token_hash == Manubrium.hash(token)
      assert device.token_hint == String.slice(token, -4, 4)

      assert Manubrium.redeem(secret, %{}, "10.0.0.1") == {:error, :invalid}
    end

    test "refuses an expired code", %{scope: scope} do
      %{secret: secret} = code(scope)
      Repo.update_all(ConnectCode, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])

      assert Manubrium.redeem(secret, %{}, "10.0.0.2") == {:error, :invalid}
    end

    test "stops listening to an address after too many wrong codes" do
      for _ <- 1..RateLimit.config(:manubrium_redeem).max do
        assert Manubrium.redeem("nope", %{}, "10.0.0.3") == {:error, :invalid}
      end

      assert Manubrium.redeem("nope", %{}, "10.0.0.3") == {:error, :rate_limited}
      # Another address is a separate count.
      assert Manubrium.redeem("nope", %{}, "10.0.0.4") == {:error, :invalid}
    end
  end

  describe "tokens" do
    test "authenticate until withdrawn, from the account page or the phone", %{scope: scope} do
      {device, token} = device(scope)

      assert {:ok, %Device{id: id, user: user}} = Manubrium.authenticate(token)
      assert id == device.id
      assert user.id == scope.user.id
      assert Manubrium.authenticate("mnb_wrong") == :error
      assert Manubrium.authenticate("not even the prefix") == :error

      assert [%Device{id: ^id}] = Manubrium.list_devices(scope)
      assert Manubrium.revoke_device(user_scope_fixture(), id) == {:error, :not_found}
      assert {:ok, _} = Manubrium.revoke_device(scope, id)

      assert Manubrium.authenticate(token) == :error
      assert Manubrium.list_devices(scope) == []

      {_device, token2} = device(scope)
      {:ok, phone} = Manubrium.authenticate(token2)
      {:ok, _} = Manubrium.revoke(phone)
      assert Manubrium.authenticate(token2) == :error
    end

    test "any_active? sees an unused code or a live device", %{scope: scope} do
      refute Manubrium.any_active?()
      %{secret: secret} = code(scope)
      assert Manubrium.any_active?()

      {:ok, device, _token} = Manubrium.redeem(secret, %{}, "10.0.0.5")
      assert Manubrium.any_active?()

      {:ok, _} = Manubrium.revoke(device)
      refute Manubrium.any_active?()
    end
  end

  describe "the device's phone code" do
    setup %{scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "App", "type" => "swiss"})
      {device, _token} = device(scope)
      %{t: t, device: device}
    end

    test "is one claimed deputy code per tournament, reused", %{t: t, device: device} do
      assert {:ok, %Enrollment{} = e} = Manubrium.enrollment_for(device, t.id)
      assert e.level == "deputy"
      assert e.device_id == device.id
      assert e.user_id == device.user_id
      refute is_nil(e.claimed_at)

      assert {:ok, %Enrollment{id: same}} = Manubrium.enrollment_for(device, t.id)
      assert same == e.id
    end

    test "is refused where the account has no role", %{device: device} do
      {:ok, other} =
        Tournaments.create_tournament(user_scope_fixture(), %{
          "name" => "Not mine",
          "type" => "swiss"
        })

      assert {:error, _reason} = Manubrium.enrollment_for(device, other.id)
    end

    test "dies with the device", %{t: t, device: device} do
      {:ok, e} = Manubrium.enrollment_for(device, t.id)
      {:ok, _} = Manubrium.revoke(device)

      refute is_nil(Repo.get!(Enrollment, e.id).revoked_at)
      assert Mobile.get_active_for_device(device.id, t.id) == nil
    end
  end
end
