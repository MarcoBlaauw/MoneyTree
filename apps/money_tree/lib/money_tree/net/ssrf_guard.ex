defmodule MoneyTree.Net.SsrfGuard do
  @moduledoc """
  Validates outbound destination URLs supplied (directly or indirectly) by
  authenticated users before the application dials them.

  This does not block private/loopback addresses -- some integrations (e.g.
  a self-hosted Ollama instance) are legitimately expected to live on
  localhost or the local network. It blocks destinations that have no
  legitimate use as an application-integration endpoint and are the classic
  SSRF targets: link-local addresses (which is where cloud metadata services
  such as 169.254.169.254 live), multicast, and unspecified/broadcast
  addresses. Validation is performed against the *resolved* IP address, not
  the literal hostname string, so hex/octal/decimal IP-encoding tricks and
  DNS names that merely point at a disallowed address are also caught.

  Callers that need to also exclude private ranges (because the destination
  should always be a public, operator-approved service) should layer
  additional checks on top of this guard rather than relying on it alone.
  """

  @type reason :: :invalid_url | :resolution_failed | :destination_not_allowed

  @spec validate(String.t() | nil) :: :ok | {:error, reason()}
  def validate(url) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         {:ok, addresses} <- resolve(uri.host) do
      if Enum.all?(addresses, &allowed?/1) do
        :ok
      else
        {:error, :destination_not_allowed}
      end
    end
  end

  def validate(_url), do: {:error, :invalid_url}

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %URI{scheme: scheme, host: host}}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    ipv4 = resolve_family(charlist, :inet)
    ipv6 = resolve_family(charlist, :inet6)
    addresses = ipv4 ++ ipv6

    if addresses == [] do
      {:error, :resolution_failed}
    else
      {:ok, addresses}
    end
  end

  defp resolve_family(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  # IPv4: reject link-local (169.254.0.0/16, where cloud metadata services
  # live), unspecified, broadcast, and multicast.
  defp allowed?({169, 254, _, _}), do: false
  defp allowed?({0, 0, 0, 0}), do: false
  defp allowed?({255, 255, 255, 255}), do: false
  defp allowed?({first, _, _, _}) when first >= 224 and first <= 239, do: false

  # IPv6: reject unspecified (::), link-local (fe80::/10), and multicast (ff00::/8).
  defp allowed?({0, 0, 0, 0, 0, 0, 0, 0}), do: false

  defp allowed?({first, _, _, _, _, _, _, _})
       when first >= 0xFE80 and first <= 0xFEBF,
       do: false

  defp allowed?({first, _, _, _, _, _, _, _}) when first >= 0xFF00 and first <= 0xFFFF,
    do: false

  defp allowed?(tuple) when tuple_size(tuple) in [4, 8], do: true
  defp allowed?(_other), do: false
end
