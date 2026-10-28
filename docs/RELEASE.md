# Putting Dairee on the server and the stores

## 1. The server (once)

1. **SkAuth knows Dairee.** On the SkAuth service in Dokploy, add Dairee to `SKAUTH_APPS`:
   `{"id":"dairee","name":"Dairee","site":"https://dairee.skifi.co","api":"https://dairee.skifi.co","color":"#1F5FD6"}`
   and redeploy SkAuth.
2. **The image is public.** After the first Server run on `main`, open GitHub > NAVICORP > Packages > `dairee` > Package settings and set the visibility to Public (or give Dokploy a token that can read it).
3. **Dokploy compose.** New compose `dairee` from GitHub `NAVICORP/dairee`, branch `main`, compose path `./deploy/docker-compose.yml`. Domain `dairee.skifi.co` to service `site`, port 8000, HTTPS on. Deploy.
4. **DNS.** On Cloudflare, skifi.co: an A record `dairee` to the VPS (179.198.218.204).
5. Open https://dairee.skifi.co/health. It says `{"ok":true}`. The web app is at https://dairee.skifi.co/app/.
6. **Redeploy on every push (optional).** GitHub > NAVICORP/dairee > Settings > Secrets and variables > Actions: variables `DOKPLOY_URL` (`https://deploy.skifi.co`) and `DOKPLOY_COMPOSE_IDS` (the compose id), secret `DOKPLOY_TOKEN` (a Dokploy API key). The Server run then redeploys after each new image.

The database moves forward by itself: on start, the API applies any migration it has not run yet.

## 2. Android

1. Make the upload key once and keep it, with its passwords, in your password manager:
   `keytool -genkey -v -keystore dairee-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`
2. GitHub > NAVICORP/dairee > Settings > Secrets and variables > Actions, add:
   - `ANDROID_KEYSTORE_B64`: the file as base64 (`base64 -i dairee-upload.jks | pbcopy` on a Mac)
   - `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`upload`), `ANDROID_KEY_PASSWORD`
3. Every push then builds `dairee-android-bundle` (the .aab) next to the test APK, under Actions > the run > Artifacts.
4. Play Console > Create app: name **Dairee**, package `co.skifi.dairee`, free, app.
5. Upload the .aab to **Internal testing** first, then Closed testing, then production.
6. App content:
   - Privacy policy: https://dairee.skifi.co/privacy
   - App access: give the review account (section 4).
   - Ads: none. Data safety: collects phone number or email (sign-in), name, and what the farm enters about its customers; nothing shared, nothing sold, encrypted in transit, deletion at https://dairee.skifi.co/delete-account.
7. **Updates.** Raise `version:` in `app/pubspec.yaml` (1.0.1, 1.0.2, ...). The version code is the App run number, so every build is higher than the last.

## 3. iPhone

No Mac needed: GitHub Actions builds the app and uploads it to TestFlight, the same way as Kuree.

1. Apple Developer > Identifiers: register the bundle id `co.skifi.dairee`.
2. App Store Connect > Apps > New App: iOS, name **Dairee**, bundle id `co.skifi.dairee`, SKU `dairee`.
3. Repository secrets (the same values Kuree uses): `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_P8`.
4. Actions > App > Run workflow, tick **testflight**. The build shows in TestFlight once Apple has processed it.

## 4. The review account

Both stores need a way in without a WhatsApp code. Make an email account with a password once (an address you can open, for example review@skifi.co):

```
curl -X POST https://dairee.skifi.co/auth/v1/signup -H 'apikey: public' -H 'content-type: application/json' \
  -d '{"email":"review@skifi.co","password":"choose-a-long-one"}'
```

Confirm the email it sends, sign in once in the app with Email > Use a password, and start a sample farm with a few customers. Give that email and password to both stores. For the customer side, give the reviewers a sample customer's number and password too (Customers > the customer > Portal password).

## 5. Store listing

- Name: Dairee. Icon: `app/assets/brand/icon.png` (1024 x 1024).
- Screenshots: the `screens` branch has a picture of every main screen after each build (phone, and computer for the web).
- Support email: contact@skifi.co. Website: https://dairee.skifi.co
