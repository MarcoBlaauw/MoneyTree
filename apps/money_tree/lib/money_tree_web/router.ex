defmodule MoneyTreeWeb.Router do
  use MoneyTreeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug MoneyTreeWeb.Plugs.Authenticate
  end

  pipeline :api_owner do
    plug MoneyTreeWeb.Plugs.Authenticate, roles: [:owner]
  end

  scope "/api", MoneyTreeWeb do
    pipe_through :api

    get "/healthz", HealthController, :health
    get "/metrics", HealthController, :metrics
    post "/register", AuthController, :register
    post "/login", AuthController, :login

    scope "/teller" do
      post "/webhook", TellerWebhookController, :webhook

      scope "/" do
        pipe_through :api_auth

        post "/connect_token", TellerController, :connect_token
        post "/exchange", TellerController, :exchange
        post "/revoke", TellerController, :revoke
      end
    end

    scope "/" do
      pipe_through :api_auth

      delete "/logout", AuthController, :logout
      get "/me", AuthController, :me
    end

    scope "/owner" do
      pipe_through :api_owner

      get "/dashboard", AuthController, :owner_dashboard
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:money_tree, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: MoneyTreeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
