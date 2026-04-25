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

  pipeline :browser_proxy do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {MoneyTreeWeb.Layouts, :root}
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
      get "/accounts", AccountController, :index
      get "/settings", SettingsController, :show
      put "/settings/profile", SettingsController, :update_profile
      put "/settings/notifications", SettingsController, :update_notifications

      post "/settings/security/webauthn/registration-options",
           SettingsController,
           :create_webauthn_registration_options

      post "/settings/security/webauthn/authentication-options",
           SettingsController,
           :create_webauthn_authentication_options

      post "/settings/security/webauthn/register",
           SettingsController,
           :complete_webauthn_registration

      delete "/settings/security/webauthn/credentials/:id",
             SettingsController,
             :revoke_webauthn_credential

      get "/obligations", ObligationController, :index
      post "/obligations", ObligationController, :create
      get "/obligations/:id", ObligationController, :show
      put "/obligations/:id", ObligationController, :update
      delete "/obligations/:id", ObligationController, :delete
      get "/mortgages", MortgageController, :index
      post "/mortgages", MortgageController, :create
      get "/mortgages/:id", MortgageController, :show
      put "/mortgages/:id", MortgageController, :update
      delete "/mortgages/:id", MortgageController, :delete
      post "/accounts/:account_id/invitations", InvitationController, :create
      delete "/accounts/:account_id/invitations/:id", InvitationController, :revoke
      get "/categorization/rules", CategorizationController, :list_rules
      post "/categorization/rules", CategorizationController, :create_rule
      delete "/categorization/rules/:id", CategorizationController, :delete_rule
      post "/categorization/recategorize", CategorizationController, :recategorize
      get "/manual-imports", ManualImportController, :index
      post "/manual-imports", ManualImportController, :create
      get "/manual-imports/:id", ManualImportController, :show
      put "/manual-imports/:id/mapping", ManualImportController, :update_mapping
      post "/manual-imports/:id/parse", ManualImportController, :parse
      get "/manual-imports/:id/rows", ManualImportController, :rows
      patch "/manual-imports/:id/rows", ManualImportController, :update_rows
      post "/manual-imports/:id/commit", ManualImportController, :commit
      post "/manual-imports/:id/rollback", ManualImportController, :rollback
    end

    scope "/plaid" do
      post "/webhook", PlaidWebhookController, :webhook

      scope "/" do
        pipe_through :api_auth

        post "/link_token", PlaidController, :link_token
        post "/exchange", PlaidController, :exchange
      end
    end

    scope "/stripe" do
      pipe_through :api_auth

      post "/session", StripeController, :session
    end

    scope "/kyc" do
      pipe_through :api_auth

      post "/session", KycController, :create_session
    end

    scope "/owner" do
      pipe_through :api_owner

      get "/dashboard", AuthController, :owner_dashboard
      resources "/users", Owner.UserController, only: [:index, :show, :update, :delete]
    end
  end

  scope "/", MoneyTreeWeb do
    pipe_through :browser

    get "/", SessionController, :new
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/login/magic", SessionController, :request_magic_link
    post "/login/webauthn/options", SessionController, :request_webauthn_options
    post "/login/webauthn", SessionController, :consume_webauthn
    get "/login/magic/:token", SessionController, :consume_magic_link
    delete "/logout", SessionController, :delete
  end

  scope "/app/react" do
    pipe_through [:browser_proxy, :require_authenticated_user]

    forward "/", MoneyTreeWeb.Plugs.NextProxy
  end

  scope "/", MoneyTreeWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/app/import-export/transactions.csv", ImportExportController, :transactions_csv
    get "/app/import-export/budgets.csv", ImportExportController, :budgets_csv

    get "/app", AppController, :index
    get "/app/accounts/connect", AppController, :accounts
    get "/app/categorization", AppController, :categorization

    live_session :app,
      on_mount: [MoneyTreeWeb.Plugs.RequireAuthenticatedUser] do
      live "/app/dashboard", DashboardLive
      live "/app/accounts", AccountsLive.Index
      live "/app/transactions", TransactionsLive.Index
      live "/app/transactions/categorization", CategorizationLive.Index
      live "/app/obligations", ObligationsLive.Index
      live "/app/assets", AssetsLive.Index
      live "/app/transfers", TransfersLive
      live "/app/budgets", BudgetLive.Index
      live "/app/import-export", ImportExportLive.Index
      live "/app/settings", SettingsLive, :index
      live "/app/settings/:section", SettingsLive, :section
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
