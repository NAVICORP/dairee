# Dairee on SkiFi's own server (dairee.skifi.co), on the shared SkiFi app base:
# the database API, sign-in through SkAuth, and the server functions.
#
# GitHub Actions builds the web app first (flutter build web, into
# app/build/web) and then this image, pushed as ghcr.io/navicorp/dairee.
# The same image runs twice (deploy/docker-compose.yml): as the API, and as
# the site in front of it (server/site.mjs), which also serves the web app.
FROM ghcr.io/navicorp/skifi-app:latest
COPY supabase/migrations /srv/app/migrations
COPY supabase/functions /srv/app/functions
COPY server /srv/site/server
COPY web /srv/site/web
COPY app/build/web /srv/site/app
ENV SITE_ROOT=/srv/site/web APP_ROOT=/srv/site/app
USER node
