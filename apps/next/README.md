This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Owner user management flow

Workspace owners can manage account access directly from the Next.js app.

1. Open `/owner/users` (there are quick links in the authenticated home page
   and the control panel header for owners).
2. The route bootstraps the current session with `fetchWithSession` and
   verifies that the signed-in user has the owner role. Guests and members see
   descriptive guidance on how to proceed.
3. Owners can search by email, sort the directory, update roles via the inline
   select, and suspend/reactivate users. Updates are optimistic and roll back
   with an inline error message if the Phoenix API rejects the change.
4. The table surfaces role, suspension state, and important timestamps so that
   owners can quickly audit their workspace.

The owner management UI exercises the `/api/owner/users` Phoenix endpoints and
reuses the same session bootstrap logic as the control panel. All requests are
made with the current CSRF token so that they behave the same way as the
Phoenix UI.
