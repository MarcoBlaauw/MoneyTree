# Contracts

This package stores the API contracts that power MoneyTree. It bundles the source
specifications (OpenAPI and GraphQL) together with the tooling required to
generate TypeScript assets that can be consumed by both the Phoenix frontend and
the Next.js application.

## Layout

```
apps/contracts/
├── package.json               # Tooling dependencies and scripts
├── specs/                     # Source-of-truth API specifications
│   ├── openapi.yaml           # REST contract (OpenAPI)
│   └── graphql/               # GraphQL documents and operations
│       └── queries/
└── src/generated/             # Generated TypeScript artifacts
```

The generated files are intended to be imported directly by other workspace
packages (for example `@moneytree/contracts/src/generated`).

## Regenerating artifacts

1. Install dependencies (first run only):
   ```sh
   pnpm install --filter @moneytree/contracts...
   ```
2. Generate the artifacts:
   ```sh
   pnpm --filter @moneytree/contracts... run generate
   ```

The `generate` script rebuilds all OpenAPI and GraphQL outputs. These artifacts
should be committed alongside any specification changes.

## Verification in CI

A `verify` script ensures the checked-in artifacts stay in sync with the source
specifications. The script is wired into the main CI workflow so pull requests
will fail if regeneration is required. You can run the same check locally with:

```sh
pnpm --filter @moneytree/contracts... run verify
```

Running `verify` will exit with a non-zero code whenever the generated files do
not match the current specs, prompting you to re-run `generate`.
