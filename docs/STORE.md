# Dairee: store listing

Everything to paste into Google Play Console and App Store Connect. The pictures are on the `store-pictures` branch under `store/` (made by `tools/store/make.cjs` from the demo farm's screens, so no real names are shown).

## Both stores

- App name: **Dairee: Dairy Farm Manager** (taken on both stores on 29 Oct 2026)
- Developer: SkiFi (SKIFI GROUP LLC)
- Category: **Business** (App Store secondary: Productivity)
- Website: https://dairee.skifi.co
- Support: https://dairee.skifi.co/support, contact@skifi.co, +91 78270 87878
- Privacy policy: https://dairee.skifi.co/privacy
- Terms: https://dairee.skifi.co/terms
- Account deletion: https://dairee.skifi.co/delete-account (also in the app: Profile > Delete account)
- Price: free, no in-app purchases, no ads
- Copyright: 2026 SKIFI GROUP LLC

| | |
|---|---|
| Google Play app | Dairee: Dairy Farm Manager, co.skifi.dairee, app id 4972068880229765417 |
| App Store app | Dairee: Dairy Farm Manager, bundle co.skifi.dairee, SKU dairee, Apple ID 6828269207 |
| App Store link once live | https://apps.apple.com/app/id6828269207 |
| Play link once live | https://play.google.com/store/apps/details?id=co.skifi.dairee |

**Subtitle** (App Store, 30 max)

```
Milk rounds, bills and herd
```

**Promotional text** (App Store, 170 max)

```
Tick every door on the round, pack the right bottles and send bills that add up. Your customers see their own milk on their phone.
```

**Short description** (Google Play, 80 max)

```
Run your dairy: milk rounds, packing, customer bills and the herd in one app.
```

**Keywords** (App Store, 100 max)

```
dairy,milk,milk delivery,milkman,dairy farm,milk round,milk billing,cattle,herd,cow,doodh,gwala
```

**Full description** (the same text on both stores)

```
Dairee runs a dairy farm from your phone: the milk round, packing, customers, bills, payments and the herd.

It is made for farms that deliver milk to homes and shops every morning and evening. Dairee keeps the record. It never takes or moves money; customers pay the farm the way they always have.

TICK EVERY DOOR
- The round by building, with how much each house takes and in what bottle or can.
- Tick each delivery. Litres out and stops to go are worked out as you go.
- No signal on the round? Keep ticking. Ticks wait on the phone and go out when the signal is back.

PACKING IN ONE LOOK
- Every bottle and can to fill for tomorrow, for each round and each building.

PAUSE, STOP OR MORE FOR A DAY
- Pause a customer, stop them, or change the milk for one day.
- The round, the packing and the bill follow by themselves.

BILLS THAT ADD UP
- Monthly bills from what actually went out, at each day's price.
- Record payments, advances and discounts. See who still has to pay.
- Share a bill as a PDF.

YOUR CUSTOMERS SEE THEIR OWN MILK
- Every delivery, every bill and what is left to pay, on their phone, from your farm's link.
- They can pause a day or ask for more. You say yes or no.
- Nothing for them to install.

KNOW YOUR HERD
- Each cow's milk, calvings and checkups, next to what went out on the rounds.

RUN IT TOGETHER
- Add staff by WhatsApp number or email and turn each page on or off for each person.
- Delivery staff see just their stops. Money stays with who you choose.
- Every change is kept, and by whom.
- Download customers, deliveries, bills, payments and the herd as spreadsheets.

NOTIFICATIONS THAT MATTER
- The office hears when a customer pauses or asks for more milk, and when a problem is reported at a door.
- Delivery staff get a reminder before each round, with the stops and litres.
- Customers hear when a bill is ready, a payment is recorded or their request is answered.

Sign in with Google, Apple, a code on WhatsApp or by email. Delete your account any time from your Profile.

Privacy: https://dairee.skifi.co/privacy
Terms: https://dairee.skifi.co/terms
```

**What's new** / release notes for 1.0.0

```
The first release of Dairee: the milk round, packing, pauses, bills and payments, the customer's page, the herd and staff.
```

**What's new in 1.0.1** (App Store and Google Play, 4000 max)

```
A new delivery screen. Pick the day and the morning or evening round, see how far the round has got, and work through every building: tick each door, take back the bottle, and see the bottles still out from earlier days. Filter by building, delivery person or quantity, and report a problem at any door.
```

**What's new in 1.0.2** (Google Play; on the App Store this build goes out as 1.0.1, still in review)

```
A fresh look in clear glass, with a new loading screen.
Notifications: customer requests, problems on the round, round reminders, and bills and payments for customers.
Sign in with Google, and with Apple on iPhone.
Bills and reports stop at today, pauses follow each customer's own rounds, and many small fixes.
```

## Google Play

- App category: Business. Tags: Business, Productivity.
- Contains ads: No. Advertising ID: No. In-app purchases: No.
- Target audience: 18 and over.
- Content rating: all other app types; no ratings-relevant content, no user content sharing (a customer's note on a delivery change goes only to their farm), no online content, nothing age-restricted, no location sharing, no digital purchases. Result: Everyone / All ages.
- Financial features: none. Dairee records bills and payments; it does not process or move money.
- Government app: No. Health features: none (the herd is cattle, not people).
- Data safety: nothing shared; encrypted in transit; account created with username, password and other authentication; deletion at https://dairee.skifi.co/delete-account.

| Data | Required | Why |
|---|---|---|
| Name | Yes | App functionality, account management |
| Email address | No (a phone number works instead) | App functionality, account management |
| Phone number | Yes (customers sign in with it) | App functionality, account management |
| Address (customers' delivery address) | No | App functionality |
| Purchase history (customers' bills and payments) | Yes | App functionality |
| Other user-generated content (notes, herd records) | No | App functionality |

## App Store

- Age rating: every question None or No, giving 4+.
- App Privacy: Data used to track you: none. Data linked to you, all for App Functionality: Contact info (name, email address, phone number, physical address), Purchases (purchase history), User content (other user content).
- Export compliance: no non-exempt encryption (ITSAppUsesNonExemptEncryption is false in Info.plist).
- Pricing: free, all countries and regions.

## Pictures and video

- Store pictures: `tools/store/make.cjs` (App Store 1290 x 2796, Play 1080 x 1920, feature graphic, icon). App Store header and search results pictures: `tools/store/creative.cjs`, uploaded to the Asset Library by Actions > Store creative assets. All on the `store-pictures` branch under `store/`.
- Intro video (1920 x 1080, 37 s) and YouTube thumbnail (1280 x 720): `tools/store/video.cjs` and `tools/store/music.py`. Upload it to YouTube (Public or Unlisted, ads off, not made for kids, not age restricted), then put the link in Play's store listing under Video.

**YouTube title**

```
Dairee: run your dairy from your phone
```

**YouTube description**

```
Dairee runs a small dairy from one phone: the morning and evening milk rounds, packing, pauses and changes for any day, monthly bills and payments, and the herd.

Tick every door on the round, see who still has to pay, and let customers see their own milk, bills and a code to pay on their phone. Record milking, health and breeding for every cow.

Free on Android, iPhone and the web: https://dairee.skifi.co
```

## The review account

Both stores sign in with the same account, the one Kuree's reviewers use: **contact@skifi.co** with its review password (the owner types it in; it is never written down here). Sign in with Email > Use a password. That account is the admin of a sample farm, **Sample Dairy**, full of made-up customers, rounds, bills and cows (supabase/migrations/0010_review_farm.sql). To delete the account: Profile > Delete account (please don't, on the review account).

Review notes (both stores). Rewritten 4 Nov 2026 after Apple asked for more information under Guideline 2.1 (purpose, how to use it, services, regions, regulation). Apple also wants a screen recording on a real iPhone, from launch through sign-in, the main pages and Delete account, attached under App Review Information > Attachment.

```
1. What Dairee is for
Dairee is for small dairy farms that deliver milk to homes, shops and hotels every morning and evening. Most of them keep this in notebooks and spreadsheets. Dairee keeps it in one place: who gets how much milk, the delivery round door by door, pauses and one-day changes, empty bottles to collect, monthly bills, payments received and what each customer still owes, and milking, health and breeding records for each cow. The owner adds staff (delivery, office, cow care), and each sees only their part. Customers can sign in to see their own milk, bills and payments and ask for changes. Any farm can sign up and use it; it is not made for one particular business.

2. How to use it
- Tap I work at a farm, then Email, then Use a password, and sign in with the account in Sign-in Information. It opens Sample Dairy, a farm with made-up customers, rounds, bills and cows.
- Today: the morning round. Tap Deliver at a door to mark it delivered, Collect when empty bottles come back. Switch between Morning and Evening at the top.
- Customers: open any customer to see their milk, money and history. Pause and Change a day are there too.
- To collect: who still owes money, with bills and payments. Record payment adds one.
- Profile, under Farm: Packing, Reports, Cows, Staff and Settings.
- The customer side: open Customers, pick a customer and tap Give a password. Sign out, tap I'm a customer, and sign in with that customer's number and the password shown. The customer sets their own password first.
- A new farm: sign in with an email code, then Start a farm.
- Delete account: Profile, then Delete account. Please don't delete the review account; it holds the sample farm.

3. Services the app uses
- Dairee's own server and PostgreSQL database at dairee.skifi.co, run by SKIFI GROUP LLC.
- SkAuth, SkiFi's own sign-in service at account.skifi.co (email code, WhatsApp code or password).
- Resend sends the email codes. Meta's WhatsApp Business Platform sends the WhatsApp codes.
- No payment processor, in-app purchases, ads, analytics or AI services. Dairee never takes or moves money: customers pay the farm directly (cash, UPI or bank) and the farm records the payment.

4. Regions
Dairee works the same in every region. Each farm chooses its currency in Settings, and email sign-in works everywhere.

5. Regulated industry or third-party material
Dairee only keeps a farm's own records. It does not sell milk, handle money, give veterinary advice or show licensed third-party material, so no licences or permissions apply.
```
