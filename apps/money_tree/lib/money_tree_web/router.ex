defmodule MoneyTreeWeb.Router do
  use MoneyTreeWeb, :router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {MoneyTreeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MoneyTreeWeb.Plugs.FetchCurrentUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug MoneyTreeWeb.Plugs.Authenticate
  end

  pipeline :api_owner do
    plug MoneyTreeWeb.Plugs.Authenticate, roles: [:owner]
  end

  pipeline :require_authenticated_user do
    plug MoneyTreeWeb.Plugs.RequireAuthenticatedUser
  end

  scope "/api", MoneyTreeWeb do
    pipe_through :api

    get "/healthz", HealthController, :health
    get "/metrics", HealthController, :metrics
    post "/register", AuthController, :register
    post "/login", AuthController, :login
    post "/invitations/:token/accept", InvitationController, :accept

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

      get "/mock-auth", MockAuthController, :show
      delete "/logout", AuthController, :logout
      get "/me", AuthController, :me
      post "/accounts/:account_id/invitations", InvitationController, :create
      delete "/accounts/:account_id/invitations/:id", InvitationController, :revoke
    end

    scope "/plaid" do
      pipe_through :api_auth

      post "/link_token", PlaidController, :link_token
    end

    scope "/kyc" do
      pipe_through :api_auth

      post "/session", KycController, :create_session
    end

    scope "/owner" do
      pipe_through :api_owner

      get "/dashboard", AuthController, :owner_dashboard
    end
  end

  scope "/", MoneyTreeWeb do
    pipe_through :browser

    get "/", SessionController, :new
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  scope "/app/react" do
    pipe_through [:browser, :require_authenticated_user]

    forward "/", MoneyTreeWeb.Plugs.NextProxy
  end

  scope "/", MoneyTreeWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/app", AppController, :index

    live_session :app,
      on_mount: [MoneyTreeWeb.Plugs.RequireAuthenticatedUser] do
      live "/app/dashboard", DashboardLive
      live "/app/transfers", TransfersLive
      live "/app/settings", SettingsLive
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
