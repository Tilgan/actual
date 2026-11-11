FROM node:22-alpine AS builder

# Install required build packages
RUN apk add --no-cache python3 openssl build-base bash git

WORKDIR /app

COPY .yarn ./.yarn
COPY yarn.lock package.json .yarnrc.yml tsconfig*.json lage.config.js ./
COPY bin ./bin
COPY packages ./packages

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

# Install dependencies and compile the browser UI + sync-server
ENV NODE_OPTIONS="--max-old-space-size=4096"
RUN yarn install && yarn build:browser && yarn build:server

# Focus the workspaces in production mode
RUN yarn workspaces focus @actual-app/sync-server --production

# better-sqlite3 only ships prebuilt binaries for x64 and arm64, so compile it
# on any other architecture (armv6/armv7 images).
RUN if [ "$(node node_modules/better-sqlite3/lib/binding.js)" = "0" ]; then \
      cd node_modules/better-sqlite3 && node ../node-gyp/bin/node-gyp.js rebuild --release; \
    fi

# Dereference yarn's workspace:* symlinks so the prod stage can copy just node_modules.
RUN cp -RL node_modules node_modules.real \
    && rm -rf node_modules \
    && mv node_modules.real node_modules

# Strip dev-only content from dereferenced workspace packages to keep the final image lean.
RUN find node_modules/@actual-app -maxdepth 2 -type d \
    \( -name src -o -name e2e -o -name __tests__ -o -name __mocks__ -o -name tests -o -name test -o -name build-stats \) \
    -exec rm -rf {} +

FROM node:22-alpine AS prod

# Minimal runtime dependencies
RUN apk add --no-cache tini

# Create a non-root user
ARG USERNAME=actual
ARG USER_UID=1001
ARG USER_GID=$USER_UID
RUN addgroup -S ${USERNAME} -g ${USER_GID} && adduser -S ${USERNAME} -G ${USERNAME} -u ${USER_UID}
RUN mkdir /data && chown -R ${USERNAME}:${USERNAME} /data

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

ENTRYPOINT ["/sbin/tini","-g",  "--"]
EXPOSE 5006
CMD ["node", "app.js"]