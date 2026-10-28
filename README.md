# Dairee

Run a milk round from your phone or computer: customers and their vessels, the daily round and packing, pauses and extra deliveries, bills and payments, the herd, and a portal for customers.

One Flutter app for Android, iPhone and the web (dairee.skifi.co/app), on SkiFi's own server.

## What is where

| Folder | What |
| --- | --- |
| `app/` | The Flutter app. `lib/core` talks to the server, `lib/ui/office` is the farm, `lib/ui/portal` the customer portal, `lib/ui/start` sign-in. |
| `supabase/migrations/` | The database: every rule about who sees and changes what lives here, in Postgres row security and functions. |
| `supabase/tests/` | `dairee_test.sql` runs the whole farm as its people (owner, delivery, office, another farm, a customer) and checks every rule. |
| `server/site.mjs` | The site in front of the API: the plain pages, the web app at `/app/` (with its offline shell), and the API door. |
| `web/` | The plain pages: home, privacy, terms, support, delete account. |
| `deploy/` | The Dokploy compose file. |
| `tools/` | `demo.sql`, a demo farm; `record_screens.py`, which records its answers for the screen pictures. |
| `docs/RELEASE.md` | Putting Dairee on the server and the stores. |

## How it fits together

- **Sign-in** is SkAuth at account.skifi.co (WhatsApp code, email code, or password), passed through by the shared SkiFi app base. Staff are added by the farm with a number or an email; their row links to them the first time they sign in with it. Nobody at a farm makes or resets anyone's sign-in: SkAuth is shared by every SkiFi app, so staff choose their own password (More > Choose a password) after signing in with a code.
- **Farms**: anyone who signs in can start a farm and becomes its admin. Every table carries `farm_id`, and row security keeps each farm's people inside it. The app sends the farm it is working in as `x-farm-id`.
- **The round** comes from one place, `expected_rounds`: each customer's standing quantity per round, less pauses, with one-day changes winning over pauses. The round, packing, bills and the portal all read it.
- **Money** has one answer for what is owed, the `bill_balances` view. Credit is kept by the database (`recompute_customer_credit`), never added up by the app. Settings > Check the money compares every total.
- **Customers** sign in to the portal with their mobile number and a password the farm gives them (first four letters of the name and four random digits, changed on first sign-in; eight wrong tries lock the number for 15 minutes). The portal is database functions only, with its own session tokens.
- **Offline**: delivery ticks wait in an outbox on the phone and go when the signal comes back.

## Checks

Every push runs, on GitHub Actions:

- **Server**: the migrations on a fresh Postgres, `dairee_test.sql`, the demo farm, and the site script. On `main` it builds the image (with the web app inside) to `ghcr.io/navicorp/dairee` and asks Dokploy to redeploy.
- **App**: `flutter analyze` and the tests; pictures of every main screen on the `screens` branch; the web build; a release APK. iOS on request (Actions > App > Run workflow), with TestFlight when ticked.

Running the database tests on your own Postgres:

```
psql -f supabase/tests/platform.sql
for f in supabase/migrations/*.sql; do psql -1 -f "$f"; done
psql -f supabase/tests/dairee_test.sql
```

## Changing the database

- New changes go in a new migration file, never into an old one that has run on the server.
- A migration that adds functions ends with its own `revoke execute ... from public, anon, authenticated` and the grants it needs (see `0009_app.sql`): new functions are not callable until granted.
- Add the checks to `dairee_test.sql` in the same change.
