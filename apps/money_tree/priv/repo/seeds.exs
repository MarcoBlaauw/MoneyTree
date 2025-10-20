alias Decimal
alias MoneyTree.Accounts
alias MoneyTree.Accounts.Account
alias MoneyTree.Assets.Asset
alias MoneyTree.Institutions.Institution
alias MoneyTree.Repo
alias MoneyTree.Sessions.Session
alias MoneyTree.Transactions.Transaction
alias MoneyTree.Users.User

user =
  Repo.get_by(User, email: "seed@example.com") ||
    case Accounts.register_user(%{
           email: "seed@example.com",
           password: "changeme123!",
           encrypted_full_name: "Seed User",
           role: :owner
         }) do
      {:ok, user} -> user
      {:error, changeset} -> raise "Failed to seed user: #{inspect(changeset.errors)}"
    end

institution =
  Repo.get_by(Institution, slug: "demo-bank") ||
    %Institution{}
    |> Institution.changeset(%{
      name: "Demo Bank",
      slug: "demo-bank",
      external_id: "demo-bank",
      website_url: "https://example-bank.test",
      encrypted_credentials: "api-key-123",
      metadata: %{"environment" => "demo"}
    })
    |> Repo.insert!()

account =
  Repo.get_by(Account, user_id: user.id, external_id: "demo-checking") ||
    %Account{}
    |> Account.changeset(%{
      user_id: user.id,
      institution_id: institution.id,
      name: "Demo Checking",
      currency: "USD",
      type: "depository",
      subtype: "checking",
      external_id: "demo-checking",
      current_balance: Decimal.new("1500.00"),
      available_balance: Decimal.new("1350.25"),
      encrypted_account_number: "123456789",
      encrypted_routing_number: "987654321"
    })
    |> Repo.insert!()

Repo.get_by(Asset, account_id: account.id, name: "Demo Home") ||
  %Asset{}
  |> Asset.changeset(%{
    account_id: account.id,
    name: "Demo Home",
    type: "property",
    valuation_amount: Decimal.new("350000"),
    valuation_currency: "USD",
    valuation_date: Date.utc_today(),
    ownership: "Primary residence",
    location: "123 Seed Street, Example City",
    documents: ["https://example.com/deed.pdf"],
    notes: "Seeded tangible asset",
    metadata: %{"source" => "seeds"}
  })
  |> Repo.insert!()

unless Repo.get_by(Session, user_id: user.id, context: "seed") do
  {:ok, _session, _token} =
    Accounts.create_session(user, %{
      context: "seed",
      metadata: %{"note" => "Seed session"}
    })
end

Repo.get_by(Transaction, account_id: account.id, external_id: "demo-transaction-1") ||
  %Transaction{}
  |> Transaction.changeset(%{
    account_id: account.id,
    external_id: "demo-transaction-1",
    amount: Decimal.new("-42.35"),
    currency: "USD",
    type: "card_payment",
    posted_at: DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second),
    settled_at: DateTime.add(DateTime.utc_now(), -1 * 24 * 60 * 60, :second),
    description: "Demo Coffee Shop",
    category: "dining",
    merchant_name: "Coffee Collective",
    status: "posted",
    encrypted_metadata: %{"receipt" => "A123456"}
  })
  |> Repo.insert!()

IO.puts("Seed data ready. Account #{account.external_id} belongs to #{account.currency}.")
