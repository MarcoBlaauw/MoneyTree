defmodule MoneyTree.Accounts.WebAuthn.FakeAdapter do
  @behaviour MoneyTree.Accounts.WebAuthnAdapter

  def new_registration_challenge(opts) do
    %{
      type: :registration,
      challenge: Keyword.get(opts, :bytes, "fake-registration-challenge"),
      origin: Keyword.fetch!(opts, :origin),
      rp_id: Keyword.fetch!(opts, :rp_id),
      user_verification: Keyword.get(opts, :user_verification, "preferred"),
      timeout: Keyword.get(opts, :timeout, 300),
      issued_at: System.system_time(:second),
      trusted_attestation_types: [:none]
    }
  end

  def new_authentication_challenge(opts) do
    %{
      type: :authentication,
      challenge: Keyword.get(opts, :bytes, "fake-authentication-challenge"),
      origin: Keyword.fetch!(opts, :origin),
      rp_id: Keyword.fetch!(opts, :rp_id),
      user_verification: Keyword.get(opts, :user_verification, "preferred"),
      timeout: Keyword.get(opts, :timeout, 300),
      issued_at: System.system_time(:second),
      allow_credentials: Keyword.get(opts, :allow_credentials, [])
    }
  end

  def register(attestation_object, client_data_json, _challenge_context) do
    with {:ok, payload} <- Jason.decode(client_data_json) do
      {:ok,
       %{
         credential_id: attestation_object,
         public_key: %{1 => 2, 3 => -7, -1 => 1, -2 => "fake-x", -3 => "fake-y"},
         aaguid: payload["aaguid"],
         sign_count: payload["signCount"] || 0
       }}
    end
  end

  def authenticate(
        credential_id,
        _authenticator_data,
        _signature,
        client_data_json,
        _challenge_context,
        credentials
      ) do
    with {:ok, payload} <- Jason.decode(client_data_json),
         true <- Enum.any?(credentials, fn {stored_id, _key} -> stored_id == credential_id end) do
      {:ok, %{sign_count: payload["signCount"] || 1}}
    else
      false -> {:error, :invalid_credentials}
      error -> error
    end
  end
end
