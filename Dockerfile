# OpenWA - Dockerfile
# Multi-stage build for production-ready image

# ===== Stage 1: Builder =====
# Pin the builder to the BUILD host's platform (not the target's). It only produces arch-INDEPENDENT
# artifacts (the NestJS dist/ JS and the static dashboard SPA), so it never needs to run emulated for
# the non-native target. On a multi-arch buildx build this avoids QEMU emulating the whole npm ci +
# Vite build for arm64 — which is slow AND is where the arm64 lightningcss (Vite 8's native CSS
# minifier) optional dependency fails to install ("Cannot find module lightningcss.linux-arm64-gnu.node").
# The per-arch runtime deps are installed natively in the target-platform production stage below.
# NOTE: $BUILDPLATFORM requires BuildKit (CI uses buildx; modern `docker build`/compose default to it).
FROM --platform=$BUILDPLATFORM docker.io/node:22-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    make \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy package files
COPY package*.json ./

# The postinstall hook is a real file (scripts/postinstall.js), and `npm ci` fails outright when
# a lifecycle script is missing — copy it BEFORE the install. dashboard/ and the backport patcher
# are deliberately still absent at this point, so the hook cleanly no-ops here (dashboard deps are
# installed explicitly below; the patcher only matters for the production stage).
COPY scripts/postinstall.js ./scripts/

# Install all dependencies INCLUDING devDependencies — the build needs them (`nest` from
# @nestjs/cli, plus `vite`/`typescript` for the dashboard). `--include=dev` is REQUIRED, not
# cosmetic: npm omits devDependencies whenever NODE_ENV=production is present in the build env.
# Coolify (and similar PaaS) promote every ${VAR} referenced in the compose file to a build-time
# variable, so docker-compose.yml's `NODE_ENV=${NODE_ENV:-production}` leaks NODE_ENV=production
# into this stage and a bare `npm ci` would skip @nestjs/cli → `sh: 1: nest: not found` (exit 127).
# (docker-compose.dev.yml hardcodes NODE_ENV=development, which is why the dev build never hit this.)
RUN npm ci --include=dev

# Copy source code
COPY . .

# Build the API (dist/) and the dashboard SPA (dashboard/dist/). The root `npm ci` above
# ran before the dashboard source was copied, so its postinstall hook skipped the dashboard
# deps - install them explicitly here (npm ci, reproducible from dashboard/package-lock.json).
# `--include=dev` for the same reason as above: the dashboard build needs vite/typescript
# (devDependencies), which a NODE_ENV=production build env would otherwise omit.
# Drop the incremental-build cache afterwards: it is pinned inside dist/ (so nest's deleteOutDir
# wipes it with the output), and the production stage copies dist/ wholesale — it would otherwise
# ship dead compiler metadata in every image.
RUN npm run build && npm run dashboard:ci -- --include=dev && npm run dashboard:build && rm -f dist/*.tsbuildinfo

# ===== Stage 2: Production =====
FROM docker.io/node:22-slim AS production

# Navigateur pour Puppeteer, exposé via le symlink /usr/local/bin/puppeteer-chrome
# (ce que le reste du Dockerfile/code attend).
#  - amd64 (Railway, x86_64) : Google Chrome STABLE. Le paquet Debian `chromium`
#    hard-crash en SIGTRAP (exit 133) au lancement sur le kernel Railway (6.18),
#    même avec --no-sandbox/--no-zygote/--single-process — prouvé avec
#    `chromium about:blank` sans session/profil. Le binaire lui-même est
#    incompatible ; le build Google Chrome se lance proprement. On PRÉFÈRE donc
#    google-chrome-stable à « Chrome for Testing » d'upstream (fix éprouvé).
#  - arm64 : chromium Debian (build natif ; Chrome/CfT n'a pas de build arm64).
# La .deb Chrome déclare ses propres deps → apt les résout depuis les listes de
# paquets, encore présentes ici (install AVANT `rm -rf /var/lib/apt/lists/*`).
#
# chromium-sandbox (arm64) est listé EXPLICITEMENT (pas laissé aux Recommends) pour que
# --no-install-recommends garde le binaire setuid sandbox : notre défaut force --no-sandbox
# (configuration.ts) donc il n'est pas utilisé, mais un override de PUPPETEER_ARGS sans
# --no-sandbox aurait sinon un chromium incapable de démarrer.
ARG TARGETARCH
# sqlite3 ships the CLI so an in-container scripts/backup.sh run takes online-consistent SQLite
# snapshots (.backup) instead of plain-copying a live database (which can archive a torn file).
RUN apt-get update && apt-get install -y --no-install-recommends \
    $([ "$TARGETARCH" = arm64 ] && echo "chromium chromium-sandbox") \
    fonts-liberation \
    libappindicator3-1 \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    xdg-utils \
    dumb-init \
    gosu \
    patch \
    curl \
    procps \
    sqlite3 \
    && if [ "$TARGETARCH" != arm64 ]; then \
         curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
         && apt-get install -y /tmp/chrome.deb \
         && rm -f /tmp/chrome.deb; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# Puppeteer ne télécharge PAS son propre Chromium au npm install : le navigateur
# est fourni ci-dessus (google-chrome-stable amd64 / chromium arm64) et exposé
# via le symlink /usr/local/bin/puppeteer-chrome plus bas.
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# Create app user for security
RUN groupadd -r openwa && useradd -r -g openwa openwa

WORKDIR /app

# Copy package files
COPY package*.json ./

# Backport upstream whatsapp-web.js#201832 (id._serialized -> id.$1 normalization,
# broken by WA Web 2.3000.x ~2026-07-14) into the installed dep at build time.
# The patcher self-disables once whatsapp-web.js ships the fix upstream.
# scripts/postinstall.js rides along: `npm ci` below runs the hook, which fails
# when the file is missing. With the patcher present the hook applies it in
# --best-effort mode; the explicit fatal run right after is the real gate.
COPY scripts/postinstall.js scripts/patch-wwebjs-201832.js scripts/wwebjs-201832.patch ./scripts/

# Install production dependencies only, then apply the backport patcher (needs `patch`).
RUN npm ci --omit=dev && node scripts/patch-wwebjs-201832.js && npm cache clean --force

# Expose le navigateur installé plus haut via un symlink stable.
#  - amd64 : google-chrome-stable (fix SIGTRAP Railway éprouvé — on N'utilise PAS
#    « Chrome for Testing » d'upstream ici).
#  - arm64 : chromium Debian (CfT/Chrome n'ont pas de build linux-arm64).
# `test -n` fait échouer le build franchement plutôt que de livrer une image cassée.
RUN if [ "$TARGETARCH" = arm64 ]; then \
        chrome_path=/usr/bin/chromium; \
    else \
        chrome_path=/usr/bin/google-chrome-stable; \
    fi && \
    test -n "$chrome_path" && test -x "$chrome_path" && \
    ln -s "$chrome_path" /usr/local/bin/puppeteer-chrome
ENV PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/puppeteer-chrome

# Copy built application from builder stage
COPY --from=builder /app/dist ./dist

# Copy the bundled dashboard SPA; ServeStaticModule serves it from this same process/port
# (app.module.ts resolves dashboard/dist relative to dist/). Single container, single port.
COPY --from=builder /app/dashboard/dist ./dashboard/dist

# Create data directories with correct ownership
RUN mkdir -p ./data/sessions ./data/media && \
    chown -R openwa:openwa /app

# The non-root openwa user has no home of its own (`useradd -r`, no -m). Chromium resolves the home
# dir from the passwd entry via glib's getpwuid() — it IGNORES $HOME — so it tries to read/write
# /home/openwa, which does not exist. On hardened/read-only hosts that makes the browser HARD-CRASH
# at launch (SIGTRAP/int3, logged as "chrome_crashpad_handler: --database is required"). The robust
# fix is to point Chromium's config + cache at writable, pre-created dirs via XDG_* (honored directly,
# bypassing the passwd lookup); docker-entrypoint.sh creates them owned by openwa. On a read_only
# rootfs these live on the tmpfs /tmp. HOME is kept for any other HOME-relative tooling. See #254/#242.
ENV HOME=/app/data
ENV XDG_CONFIG_HOME=/tmp/.config
ENV XDG_CACHE_HOME=/tmp/.cache

# Copy entrypoint: runs as root to fix named-volume ownership, then drops to openwa via gosu
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Expose port
EXPOSE 2785

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:2785/api/health/ready || exit 1

# dumb-init is PID 1 and handles signal forwarding.
# It execs docker-entrypoint.sh (as root), which fixes volume ownership and
# then drops to the openwa user via gosu before starting the node process.
#
# NOTE — no `USER openwa` directive on purpose (Trivy DS-0002 will flag it, ignore).
# The Node process does NOT run as root: docker-entrypoint.sh:30 is
# `exec gosu openwa "$@"` after the chowns on lines 7 and 25. Adding `USER openwa`
# here would run the entrypoint as openwa and break the chown-before-drop pattern
# that makes named-volume mounts work on first boot (#254, #259).
ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "dist/main"]
