defmodule MoneyTree.Teller.ClientTest do
  use ExUnit.Case, async: true

  alias MoneyTree.Teller.Client

  @cert_pem """
  -----BEGIN CERTIFICATE-----
  MIIDFTCCAf2gAwIBAgIUM/u+k/Zgja27umfaUrE9He2PD3kwDQYJKoZIhvcNAQEL
  BQAwGjEYMBYGA1UEAwwPbW9uZXktdHJlZS50ZXN0MB4XDTI1MTAyMTE4NTYwOFoX
  DTI2MTAyMTE4NTYwOFowGjEYMBYGA1UEAwwPbW9uZXktdHJlZS50ZXN0MIIBIjAN
  BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArs3gVuDrfnWuk9dZpxVnVrP3Au7Y
  fmecqj5zBxFKXydktKyINfnTdOj0BLqp8RNMTh1qloPIC/astgJcu5Mkndl4vy+k
  fesMBjw9rKv0SJolbp+a3Hhd0sW6Ml0zc6xlCRCTO/zy3ee500YKPAfT8vL92BHs
  Yyb31FoCOK4e3irl4Qxaz73GUTfI9YkhRkw0Ib4DXO/CSM2cafpUy4bWyeJPv69w
  oVD58/TP7ub6CshNHdJD+7O+SqAcvlKgIbaUMcnoQP0bM9jCFDXXTiEirG/OtHO3
  F2jjbbWNFXV9VPnOyf2DW48zXu187fdEoJJETWy7YltNBRnoNWyy3pv+xwIDAQAB
  o1MwUTAdBgNVHQ4EFgQUoq5/tKCq5Rzy18IxPgQNTaLrwZMwHwYDVR0jBBgwFoAU
  oq5/tKCq5Rzy18IxPgQNTaLrwZMwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
  AQsFAAOCAQEAC5B6GDUF570PVN5EjXdlXsbhuRIEjR9xQ7ho1NaAUEJ6T4InAhkt
  wosAo6Ly9DcTwqIySniHuX4hIGs3vJyl5u+SjRtpL+iaUUeu3x16vcAVlHwSnpjQ
  aL+MZqfdgStpSgHGXyE6HEQOU7C6EKSEK2HrVw0QZuZUOO69EV49cDHEofIValbf
  vS6B22Cxzj8r+xZOTa4yj100BeH27gpBZCC1g7OMymqyc70VsjsJmIY72GCYj2IA
  WdSlhSalCzkDLN2HyDu3C/cR3IIv2oLD888MtozGL6zCLutg1G6XWKiXWFFQSI2o
  K5WeKRMTGmXxzQaEwNWasd4A8POCHoPyCQ==
  -----END CERTIFICATE-----
  """

  @key_pem """
  -----BEGIN PRIVATE KEY-----
  MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCuzeBW4Ot+da6T
  11mnFWdWs/cC7th+Z5yqPnMHEUpfJ2S0rIg1+dN06PQEuqnxE0xOHWqWg8gL9qy2
  Aly7kySd2Xi/L6R96wwGPD2sq/RImiVun5rceF3SxboyXTNzrGUJEJM7/PLd57nT
  Rgo8B9Py8v3YEexjJvfUWgI4rh7eKuXhDFrPvcZRN8j1iSFGTDQhvgNc78JIzZxp
  +lTLhtbJ4k+/r3ChUPnz9M/u5voKyE0d0kP7s75KoBy+UqAhtpQxyehA/Rsz2MIU
  NddOISKsb860c7cXaONttY0VdX1U+c7J/YNbjzNe7Xzt90SgkkRNbLtiW00FGeg1
  bLLem/7HAgMBAAECggEAFfi3qYPk5cTJ+Dg5wxgcIJhHRH2cBatlVDq8P5erRvGP
  JWyIRGyN6SR8w3lo8e3QigMFijyvMN3FEK2UVVll4Vdb54AIB3G7Va9Nuz3z2wpR
  CSoTj4GrnVoQENOJK5FwM6b7Mq+VIVJGl6k2kRwUxnVHddiu4zmbLfxQSiqMo7UA
  OazP1Y0To9mOFZySlu7kw/23sMFHLNAzOEhLdOK0Cq+sdcarx41s09J+yYcoy0ac
  uXQnoqGVmMPKzrzTW800oNeGZB6YuoKKw2l+2vCaUuNTknN0DL/bRFAEcv7Asvf3
  SyMHkVie/pbsGNU7zEtGakCQ5szlgWcEJ46kj+VhSQKBgQDo+Z2bOby9U82/v5+S
  SmS0pwhoVtJAbGYvNnS+9SO5bW3I4WSixr3E2qu6BsgFcLidg9tb0LAvGf6h4m9/
  HuaWIs2T/oYGk4p8HWNhRS9Q/clvMmrdBPOik/Q57BSYUKEUl3+0pFFoW4Xzqlrg
  GQerKRPI+gF2I3apgFYEZo9MrwKBgQDAFIJboTnKwnxD0T9vRPPEcZK7KKSqPkFL
  KBHAoBsEdMBCBJdMpIJx5N0Kp+6mtVWoHBbaCNJrPPTXv5JTIoZjRq/nEJIfZCWl
  i0lK7r9nQguX56Ay3pPFVAku5Ni5FQuprSjN8VWuUoO3s4qYyQTpjcsqxUdSwxp8
  tFlattPlaQKBgBwQzgrAFtub9+JMnFWMPruAj8O6CdQW+uxfHAtRDr+szhfwByaQ
  2JWZXiyn2nrFTIg1NTzHVCIoeINZ+uKOf2rAwJE+jTjHl1xCUhGKuxt/pz+NDFCZ
  4xvHxRkhNo3u0KjhY1IIpYHz3Jww/oeWnFTjOu3wKDLqLMZYnoQjMsojAoGABqBu
  guTEDqe5C8nrS1ZwpoVYj5ZuX+U38XTXb/LWG8g/Xce0xJMkYPOJYLW8eQnmg588
  dpc5UzPOKqdUUAPv6PrmVK1wrR6SYey1QZ2NAu33Ym0+TKL7LCKjEngYtgHw3hC4
  SKqbzyDPpIXQMUc2ISygJsCZnlRW1JiQQJ3wH4kCgYEAgMSKn/0oLOLrxsL+gECA
  cXaujcemOmDtUupyp6/SqFm/juMAfftvt5h7dKaZqfvCOKXFakd6y41wXF5FSATb
  Mqw7DspmtyUdgSpyhK9RMjxZeZnSzVTjEyuS+54peqczlT5eDI7ATz5KEJstF9PA
  3vIdDsgxWF2D1hMnFDVcl2c=
  -----END PRIVATE KEY-----
  """

  setup do
    original = Application.get_env(:money_tree, MoneyTree.Teller, [])

    base_config =
      original
      |> Keyword.merge(
        api_key: "test-key",
        api_host: Keyword.get(original, :api_host, "https://api.teller.io"),
        connect_host: Keyword.get(original, :connect_host, "https://connect.teller.io"),
        timeout: Keyword.get(original, :timeout, :timer.seconds(10)),
        finch: Keyword.get(original, :finch, MoneyTree.Finch)
      )

    Application.put_env(:money_tree, MoneyTree.Teller, base_config)

    on_exit(fn -> Application.put_env(:money_tree, MoneyTree.Teller, original) end)

    :ok
  end

  test "adds certificate files to Req transport options" do
    update_config(client_cert_file: "/tmp/client.pem", client_key_file: "/tmp/client.key")

    client = Client.new()

    transport_opts = transport_opts(client)

    assert transport_opts[:certfile] == "/tmp/client.pem"
    assert transport_opts[:keyfile] == "/tmp/client.key"
    refute Keyword.has_key?(transport_opts, :cert)
    refute Keyword.has_key?(transport_opts, :key)
  end

  test "decodes PEM credentials into Req transport options" do
    update_config(client_cert_pem: @cert_pem, client_key_pem: @key_pem)

    client = Client.new()

    transport_opts = transport_opts(client)

    [{_type, expected_cert_der, _meta} | _] = :public_key.pem_decode(@cert_pem)
    [{expected_key_type, expected_key_der, _meta} | _] = :public_key.pem_decode(@key_pem)

    assert transport_opts[:cert] == expected_cert_der
    assert transport_opts[:key] == {expected_key_type, expected_key_der}
    refute Keyword.has_key?(transport_opts, :certfile)
    refute Keyword.has_key?(transport_opts, :keyfile)
  end

  defp update_config(overrides) do
    current = Application.get_env(:money_tree, MoneyTree.Teller, [])
    Application.put_env(:money_tree, MoneyTree.Teller, Keyword.merge(current, overrides))
  end

  defp transport_opts(client) do
    client.api_request.options[:connect_options][:transport_opts]
  end
end
