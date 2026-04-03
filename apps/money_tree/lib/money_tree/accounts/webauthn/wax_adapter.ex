defmodule MoneyTree.Accounts.WebAuthn.WaxAdapter do
  @moduledoc """
  Real WebAuthn implementation backed by Wax.
  """

  @behaviour MoneyTree.Accounts.WebAuthnAdapter

  def new_registration_challenge(opts) do
    challenge =
      opts
      |> Keyword.take([:origin, :rp_id, :user_verification, :timeout, :bytes])
      |> Wax.new_registration_challenge()

    %{
      type: :registration,
      challenge: challenge.bytes,
      origin: challenge.origin,
      rp_id: challenge.rp_id,
      user_verification: challenge.user_verification,
      timeout: challenge.timeout,
      issued_at: challenge.issued_at,
      trusted_attestation_types: challenge.trusted_attestation_types
    }
  end

  def new_authentication_challenge(opts) do
    challenge =
      opts
      |> Keyword.take([:origin, :rp_id, :user_verification, :timeout, :bytes, :allow_credentials])
      |> Wax.new_authentication_challenge()

    %{
      type: :authentication,
      challenge: challenge.bytes,
      origin: challenge.origin,
      rp_id: challenge.rp_id,
      user_verification: challenge.user_verification,
      timeout: challenge.timeout,
      issued_at: challenge.issued_at,
      allow_credentials: challenge.allow_credentials
    }
  end

  def register(attestation_object, client_data_json, challenge_context) do
    challenge = wax_challenge(challenge_context)

    case Wax.register(attestation_object, client_data_json, challenge) do
      {:ok, {auth_data, _attestation}} ->
        credential_data = auth_data.attested_credential_data

        {:ok,
         %{
           credential_id: credential_data.credential_id,
           public_key: credential_data.credential_public_key,
           aaguid: credential_data.aaguid,
           sign_count: auth_data.sign_count || 0
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  def authenticate(
        credential_id,
        authenticator_data,
        signature,
        client_data_json,
        challenge_context,
        credentials
      ) do
    challenge = wax_challenge(challenge_context)

    case Wax.authenticate(
           credential_id,
           authenticator_data,
           signature,
           client_data_json,
           challenge,
           credentials
         ) do
      {:ok, auth_data} ->
        {:ok, %{sign_count: auth_data.sign_count || 0}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp wax_challenge(context) do
    %Wax.Challenge{
      type: context.type,
      bytes: context.challenge,
      origin: context.origin,
      rp_id: context.rp_id,
      user_verification: context.user_verification,
      timeout: context.timeout,
      issued_at: context.issued_at,
      allow_credentials: Map.get(context, :allow_credentials, []),
      trusted_attestation_types:
        Map.get(context, :trusted_attestation_types, [
          :none,
          :basic,
          :uncertain,
          :attca,
          :anonca,
          :self
        ]),
      verify_trust_root: true,
      token_binding_status: nil,
      origin_verify_fun: {Wax, :origins_match?, []},
      android_key_allow_software_enforcement: false,
      silent_authentication_enabled: false
    }
  end
end
