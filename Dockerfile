FROM node:22-bookworm-slim AS builder

# Install required build packages on Debian
RUN apt-get update && apt-get install -y \
    python3 \
    openssl \
    build-essential \
    bash \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY .yarn ./.yarn
COPY yarn.lock package.json .yarnrc.yml tsconfig*.json lage.config.js ./
COPY bin ./bin
COPY packages ./packages

# Initialize a local Git repository with a HEAD commit so lage (`git ls-tree HEAD -r`) succeeds
RUN git init && \
    git config user.email "build@local" && \
    git config user.name "build" && \
    git add -A && \
    git commit -q -m "docker-build"

# Point /usr/local/bin/yarn to the repo's vendored Yarn 4 release
RUN ln -sf /app/.yarn/releases/yarn-*.cjs /usr/local/bin/yarn

# Configure Yarn concurrency and retries for Cloud Shell
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV HUSKY=0
RUN yarn config set taskPoolConcurrency 2 && \
    yarn config set networkConcurrency 5 && \
    yarn config set httpTimeout 300000 && \
    yarn config set httpRetry 5

# Install dependencies in a separate layer so Docker caches them
ENV NODE_OPTIONS="--max-old-space-size=4096"
RUN yarn install

# Ignore node_modules and cloned locale folders so lage's git hash-object succeeds, then compile
RUN ln -sf /bin/bash /bin/sh && \
    printf "node_modules/\n**/node_modules/\npackages/desktop-client/locale/\n.yarn/\n" > .gitignore && \
    git add .gitignore && \
    git commit -q -m "ignore node_modules for lage" && \
    yarn build:browser && \
    yarn build:server

# Focus the workspaces in production mode
RUN yarn workspaces focus @actual-app/sync-server --production

# Dereference yarn's workspace:* symlinks so the prod stage can copy just node_modules.
RUN cp -RL node_modules node_modules.real \
    && rm -rf node_modules \
    && mv node_modules.real node_modules

# Strip dev-only content from dereferenced workspace packages to keep the final image lean.
RUN find node_modules/@actual-app -maxdepth 2 -type d \
    \( -name src -o -name e2e -o -name __tests__ -o -name __mocks__ -o -name tests -o -name test -o -name build-stats \) \
    -exec rm -rf {} +

FROM node:22-bookworm-slim AS prod

# Minimal runtime dependencies
RUN apt-get update && apt-get install -y tini openssl && rm -rf /var/lib/apt/lists/*

# Ensure /data directory exists and is owned by the non-root node user
RUN mkdir -p /data && chown -R node:node /data

WORKDIR /app
ENV NODE_ENV=production

# sync-server entry flattened at /app so CMD stays `node app.js`.
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/packages/sync-server/package.json ./
COPY --from=builder /app/packages/sync-server/build ./

# Ensure the compiled React frontend is present in @actual-app/web/build
COPY --from=builder /app/packages/desktop-client/package.json ./node_modules/@actual-app/web/package.json
COPY --from=builder /app/packages/desktop-client/build ./node_modules/@actual-app/web/build

# script dir changed when we swapped build method, add the legacy dir in for compatibility
RUN mkdir -p src && ln -s ../scripts src/scripts

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
EXPOSE 5006
CMD ["node", "app.js"]