FROM erlang:29.0.0-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install rebar3
RUN curl -fsSL https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 -o /usr/local/bin/rebar3 && \
    chmod +x /usr/local/bin/rebar3

# Copy dependency specs first for layer caching
COPY rebar.config rebar.lock ./
RUN rebar3 compile --deps_only

# Copy source and build release
COPY config/ config/
COPY src/ src/
RUN rebar3 as prod release

# --- Runtime ---
# Must match the builder's Debian release (erlang:28.4.2-slim is trixie-based)
# so the linked-against GLIBC matches at runtime.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libncurses6 libssl3 libtinfo6 ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r asobi && useradd -r -g asobi -d /app asobi

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/asobi_lua/ ./

# Game scripts mount point
RUN mkdir -p /app/game && chown -R asobi:asobi /app
VOLUME ["/app/game"]

USER asobi
EXPOSE 8080

ENV ASOBI_PORT=8080 \
    ASOBI_NODE_HOST=127.0.0.1 \
    ASOBI_DB_HOST=db \
    ASOBI_DB_NAME=asobi \
    ASOBI_DB_USER=postgres \
    ASOBI_DB_PASSWORD=postgres

# Erlang term fragment spliced into kura's socket_options list.
# Default forces IPv4; set to "inet6" for IPv6-only Postgres networks.
ENV ASOBI_DB_SOCKET_OPTS=inet

ENTRYPOINT ["tini", "--"]
CMD ["bin/asobi_lua", "foreground"]
