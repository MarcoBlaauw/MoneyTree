defmodule MoneyTree.Accounts.WebAuthnAdapter do
  @moduledoc """
  Behaviour for WebAuthn challenge generation and verification.
  """

  @type challenge_context :: %{
          required(:type) => :registration | :authentication,
          required(:origin) => String.t(),
          required(:rp_id) => String.t(),
          required(:user_verification) => String.t(),
          required(:timeout) => non_neg_integer(),
          required(:issued_at) => integer(),
          required(:challenge) => binary(),
          optional(:allow_credentials) => list(),
          optional(:trusted_attestation_types) => list()
        }

  @callback new_registration_challenge(keyword()) :: challenge_context()
  @callback new_authentication_challenge(keyword()) :: challenge_context()

  @callback register(binary(), binary(), challenge_context()) ::
              {:ok,
               %{
                 credential_id: binary(),
                 public_key: term(),
                 aaguid: binary() | nil,
                 sign_count: non_neg_integer()
               }}
              | {:error, term()}

  @callback authenticate(binary(), binary(), binary(), binary(), challenge_context(), list()) ::
              {:ok, %{sign_count: non_neg_integer()}} | {:error, term()}
end
