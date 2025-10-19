# Third-party widget integrations

The Phoenix content security policy now whitelists the minimal set of origins required for
our embedded vendors:

- `https://cdn.plaid.com` and `https://link.plaid.com` for Plaid Link scripts and iframes
- `https://cdn.teller.io` and `https://connect.teller.io` for Teller Connect assets
- `https://withpersona.com`, `https://app.withpersona.com`, and `https://api.withpersona.com`
  for Persona KYC widgets and APIs
- `https://api.plaid.com` and `https://api.teller.io` for widget network requests

All other hosts remain blocked by the CSP. Keep the list in sync with vendor configuration
and update this document when adding a new origin.
