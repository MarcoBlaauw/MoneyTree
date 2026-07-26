defmodule MoneyTree.Net.SsrfGuard do
  @moduledoc """
  Validates outbound destination URLs supplied (directly or indirectly) by
  authenticated users before the application dials them.

  Validation is performed against the *resolved* IP address, not the literal
  hostname string, so hex/octal/decimal IP-encoding tricks and DNS names that
  merely point at a disallowed address (DNS rebinding) are caught too.

  By default (`allow_private: true`), private/loopback addresses are still
  allowed -- some integrations (e.g. a self-hosted Ollama instance) are
  legitimately expected to live on localhost or the local network. What's
  always rejected regardless of that option is link-local addresses (which
  is where cloud metadata services such as 169.254.169.254 live), multicast,
  and unspecified/broadcast addresses -- there is no legitimate
  application-integration use for those.

  Pass `allow_private: false` for integrations that should only ever be a
  public, third-party service (no legitimate deployment of that integration
  runs on a private network) -- this additionally rejects loopback and
  RFC1918/ULA ranges.
  """

  @type reason :: :invalid_url | :resolution_failed | :destination_not_allowed
  @type opt :: {:allow_private, boolean()}

  @spec validate(String.t() | nil, [opt()]) :: :ok | {:error, reason()}
  def validate(url, opts \\ [])

  def validate(url, opts) when is_binary(url) do
    allow_private? = Keyword.get(opts, :allow_private, true)

    with {:ok, uri} <- parse(url),
         {:ok, addresses} <- resolve(uri.host) do
      if Enum.all?(addresses, &allowed?(&1, allow_private?)) do
        :ok
      else
        {:error, :destination_not_allowed}
      end
    end
  end

  def validate(_url, _opts), do: {:error, :invalid_url}

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

  # Always-disallowed ranges (no legitimate integration target lives here).

  # IPv4: link-local (169.254.0.0/16, where cloud metadata services live),
  # unspecified, broadcast, and multicast.
  defp allowed?({169, 254, _, _}, _allow_private?), do: false
  defp allowed?({0, 0, 0, 0}, _allow_private?), do: false
  defp allowed?({255, 255, 255, 255}, _allow_private?), do: false
  defp allowed?({first, _, _, _}, _allow_private?) when first >= 224 and first <= 239, do: false

  # IPv6: unspecified (::), link-local (fe80::/10), and multicast (ff00::/8).
  defp allowed?({0, 0, 0, 0, 0, 0, 0, 0}, _allow_private?), do: false

  defp allowed?({first, _, _, _, _, _, _, _}, _allow_private?)
       when first >= 0xFE80 and first <= 0xFEBF,
       do: false

  defp allowed?({first, _, _, _, _, _, _, _}, _allow_private?)
       when first >= 0xFF00 and first <= 0xFFFF,
       do: false

  # Private/loopback ranges -- only disallowed when the caller opted out.
  defp allowed?({127, _, _, _}, false), do: false
  defp allowed?({10, _, _, _}, false), do: false
  defp allowed?({192, 168, _, _}, false), do: false
  defp allowed?({100, second, _, _}, false) when second >= 64 and second <= 127, do: false
  defp allowed?({172, second, _, _}, false) when second >= 16 and second <= 31, do: false
  defp allowed?({0, 0, 0, 0, 0, 0, 0, 1}, false), do: false

  defp allowed?({first, _, _, _, _, _, _, _}, false) when first >= 0xFC00 and first <= 0xFDFF,
    do: false

  defp allowed?(tuple, _allow_private?) when tuple_size(tuple) in [4, 8], do: true
  defp allowed?(_other, _allow_private?), do: false
end
