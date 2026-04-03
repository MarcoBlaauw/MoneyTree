defmodule MoneyTree.Accounts.WebAuthnTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts

  describe "user_settings/1" do
    test "includes registered passkeys and security keys" do
      user = user_fixture()

      passkey =
        webauthn_credential_fixture(user, %{
          kind: "passkey",
          label: "MacBook Touch ID",
          attachment: "platform",
          transports: ["internal"]
        })

      security_key =
        webauthn_credential_fixture(user, %{
          kind: "security_key",
          label: "YubiKey 5C",
          attachment: "cross-platform",
          transports: ["usb", "nfc"]
        })

      settings = Accounts.user_settings(user)

      assert settings.security.passkeys_count == 1
      assert settings.security.security_keys_count == 1
      assert settings.security.password_enabled == true
      assert settings.security.magic_link_enabled == true
      assert [%{id: passkey_id, label: "MacBook Touch ID"}] = settings.security.passkeys
      assert [%{id: security_key_id, label: "YubiKey 5C"}] = settings.security.security_keys
      assert passkey_id == passkey.id
      assert security_key_id == security_key.id
      assert settings.security.registration_ready == true
    end
  end

  describe "create_webauthn_registration_options/2" do
    test "creates a persisted challenge and registration options" do
      user = user_fixture(%{full_name: "Pass Key"})

      existing =
        webauthn_credential_fixture(user, %{credential_id: :crypto.strong_rand_bytes(32)})

      assert {:ok, challenge, options} =
               Accounts.create_webauthn_registration_options(user, %{"kind" => "security_key"})

      assert challenge.purpose == "registration"
      assert challenge.authenticator_attachment == "cross-platform"
      assert options.rp.id == "localhost"
      assert options.rp.name == "MoneyTree"
      assert options.user.name == user.email
      assert options.user.displayName == "Pass Key"
      assert options.authenticatorSelection.authenticatorAttachment == "cross-platform"

      assert Enum.any?(options.excludeCredentials, fn credential ->
               credential.id == Base.url_encode64(existing.credential_id, padding: false)
             end)
    end
  end

  describe "create_webauthn_authentication_options/2" do
    test "creates a persisted challenge and allow credentials list" do
      user = user_fixture()
      credential = webauthn_credential_fixture(user, %{transports: ["usb"]})

      assert {:ok, challenge, options} = Accounts.create_webauthn_authentication_options(user)

      assert challenge.purpose == "authentication"
      assert options.rpId == "localhost"
      assert options.userVerification == "preferred"

      assert [%{id: id, transports: ["usb"], type: "public-key"}] = options.allowCredentials
      assert id == Base.url_encode64(credential.credential_id, padding: false)
    end
  end
end
