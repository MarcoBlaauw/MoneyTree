defmodule MoneyTree.Accounts.WebAuthnRealAdapterTest do
  @moduledoc """
  Exercises WebAuthn registration + authentication through the real `Wax`-backed
  adapter (not `WebAuthnFakeAdapter`), which is the only adapter that performs the
  cryptographic/origin verification that a browser authenticator actually relies on.

  This guards against a regression where the request-scoped `origin`/`rp_id`
  captured when a ceremony begins (e.g. `http://localhost:4000` in dev) was silently
  discarded in favor of the app's static config default (`http://localhost`, with no
  port), causing every real passkey registration to fail server-side with an
  origin mismatch while looking like it succeeded client-side.
  """

  use MoneyTree.DataCase, async: false

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts

  @curve :secp256r1
  # Intentionally differs from the app's static default origin (`http://localhost`,
  # derived from `config :money_tree, MoneyTreeWeb.Endpoint, url: [host: "localhost"]`,
  # which has no port) the same way a real dev browser at :4000 does.
  @request_origin "http://localhost:4000"
  @rp_id "localhost"

  setup do
    previous_adapter = Application.get_env(:money_tree, :webauthn_adapter)
    Application.put_env(:money_tree, :webauthn_adapter, MoneyTree.Accounts.WebAuthn.WaxAdapter)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:money_tree, :webauthn_adapter, previous_adapter)
      else
        Application.delete_env(:money_tree, :webauthn_adapter)
      end
    end)

    :ok
  end

  test "registers and authenticates a passkey when the request origin has a port the app's static default lacks" do
    user = user_fixture()
    {public_key, private_key} = :crypto.generate_key(:ecdh, @curve)
    <<4, x::binary-size(32), y::binary-size(32)>> = public_key
    cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
    credential_id = :crypto.strong_rand_bytes(32)
    aaguid = <<0::128>>

    assert {:ok, reg_challenge, _options} =
             Accounts.create_webauthn_registration_options(user, %{
               "origin" => @request_origin,
               "rp_id" => @rp_id
             })

    assert reg_challenge.origin == @request_origin
    assert reg_challenge.rp_id == @rp_id

    attested_credential_data =
      aaguid <> <<byte_size(credential_id)::16>> <> credential_id <> CBOR.encode(cose_key)

    # flags: attested credential data present (bit 6) + user present (bit 0)
    registration_auth_data =
      :crypto.hash(:sha256, @rp_id) <>
        <<0x41>> <>
        <<0::32>> <>
        attested_credential_data

    attestation_object =
      CBOR.encode(%{"fmt" => "none", "authData" => registration_auth_data, "attStmt" => %{}})

    registration_client_data_json =
      Jason.encode!(%{
        "type" => "webauthn.create",
        "challenge" => reg_challenge.challenge,
        "origin" => @request_origin
      })

    registration_attrs = %{
      "response" => %{
        "attestationObject" => Base.url_encode64(attestation_object, padding: false),
        "clientDataJSON" => Base.url_encode64(registration_client_data_json, padding: false)
      },
      "transports" => ["internal"]
    }

    assert {:ok, credential} =
             Accounts.complete_webauthn_registration(user, reg_challenge.id, registration_attrs)

    assert credential.credential_id == credential_id

    assert {:ok, auth_challenge, _options} =
             Accounts.create_webauthn_authentication_options(user, %{
               "origin" => @request_origin,
               "rp_id" => @rp_id
             })

    assert auth_challenge.origin == @request_origin

    # flags: user present only (bit 0), no attested credential data on assertions
    authentication_auth_data =
      :crypto.hash(:sha256, @rp_id) <>
        <<0x01>> <>
        <<1::32>>

    authentication_client_data_json =
      Jason.encode!(%{
        "type" => "webauthn.get",
        "challenge" => auth_challenge.challenge,
        "origin" => @request_origin
      })

    signed_message =
      authentication_auth_data <> :crypto.hash(:sha256, authentication_client_data_json)

    signature = :crypto.sign(:ecdsa, :sha256, signed_message, [private_key, @curve])

    authentication_attrs = %{
      "id" => Base.url_encode64(credential_id, padding: false),
      "response" => %{
        "authenticatorData" => Base.url_encode64(authentication_auth_data, padding: false),
        "clientDataJSON" => Base.url_encode64(authentication_client_data_json, padding: false),
        "signature" => Base.url_encode64(signature, padding: false)
      }
    }

    assert {:ok, authenticated_user} =
             Accounts.authenticate_with_webauthn(user, auth_challenge.id, authentication_attrs)

    assert authenticated_user.id == user.id
  end
end
