defmodule MoneyTree.Currency do
  @moduledoc """
  Helpers for working with ISO 4217 currency codes.

  The codes are stored as uppercase three-letter strings and can be
  referenced for validation during changeset casting.
  """

  @iso_codes ~w(
    AED AFN ALL AMD ANG AOA ARS AUD AWG AZN
    BAM BBD BDT BGN BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD
    CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUC CUP CVE CZK
    DJF DKK DOP DZD
    EGP ERN ETB EUR
    FJD FKP
    GBP GEL GHS GIP GMD GNF GTQ GYD
    HKD HNL HRK HTG HUF
    IDR ILS INR IQD IRR ISK
    JMD JOD JPY
    KES KGS KHR KMF KPW KRW KWD KYD KZT
    LAK LBP LKR LRD LSL LYD
    MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN
    NAD NGN NIO NOK NPR NZD
    OMR
    PAB PEN PGK PHP PKR PLN PYG
    QAR
    RON RSD RUB RWF
    SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL
    THB TJS TMT TND TOP TRY TTD TWD TZS
    UAH UGX USD USN UYI UYU UYW UZS
    VED VES VND VUV
    WST
    XAF XAG XAU XBA XBB XBC XBD XCD XDR XOF XPD XPF XPT XSU XTS XUA XXX
    YER
    ZAR ZMW ZWL
  )
  @iso_code_set MapSet.new(@iso_codes)

  @spec iso_codes() :: [String.t()]
  def iso_codes, do: @iso_codes

  @spec valid_code?(term()) :: boolean()
  def valid_code?(code) when is_binary(code) do
    code
    |> String.upcase()
    |> then(&MapSet.member?(@iso_code_set, &1))
  end

  def valid_code?(_), do: false
end
