# MoneyTree

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Teller sandbox usage

The Phoenix API exposes endpoints to help the frontend exercise Teller Connect during development:

- `GET /api/teller/connect/start` – returns a sandbox Connect URL seeded with your `TELLER_CONNECT_APPLICATION_ID`.
- `POST /api/teller/webhooks` – receives Teller webhook callbacks; run a tunnel (ngrok, cloudflared, etc.) so Teller can reach
  your local server when testing end-to-end flows.

Refer to the repository root `README.md` for environment variable configuration and operational runbooks.

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
