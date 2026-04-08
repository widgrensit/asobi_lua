# Asobi Lua

Lua scripting runtime for the [Asobi](https://github.com/widgrensit/asobi)
game backend. Write your game logic in Lua — no Erlang knowledge required.

Runs Lua scripts inside the BEAM via [Luerl](https://github.com/rvirding/luerl),
giving you OTP's fault tolerance and concurrency with a language game
developers already know.

## Quick Start

```bash
mkdir my_game && cd my_game
mkdir -p lua/bots
```

Create `lua/match.lua`:

```lua
match_size = 2

function init(config)
    return { players = {}, tick_count = 0 }
end

function join(player_id, state)
    state.players[player_id] = { x = 400, y = 300, hp = 100 }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(player_id, input, state)
    local p = state.players[player_id]
    if not p then return state end
    if input.right then p.x = p.x + 5 end
    if input.left then p.x = p.x - 5 end
    if input.down then p.y = p.y + 5 end
    if input.up then p.y = p.y - 5 end
    return state
end

function tick(state)
    state.tick_count = state.tick_count + 1
    return state
end

function get_state(player_id, state)
    return { players = state.players, tick_count = state.tick_count }
end
```

Create `docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: my_game_dev
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  asobi:
    image: ghcr.io/widgrensit/asobi_lua:latest
    depends_on:
      postgres: { condition: service_healthy }
    ports:
      - "8080:8080"
    volumes:
      - ./lua:/app/game:ro
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game_dev
```

```bash
docker compose up -d
```

That's it. Asobi reads your Lua scripts from the mounted volume and handles
everything else — database, authentication, matchmaking, WebSockets.

## What's Included

This runtime bundles the full [Asobi engine](https://github.com/widgrensit/asobi)
with Lua scripting support:

- **Lua match bridge** — `asobi_lua_match` implements the `asobi_match`
  behaviour by delegating to your Lua callbacks
- **Lua world bridge** — `asobi_lua_world` for persistent world servers
- **Bot AI** — server-side bots with Lua `think()` functions
- **Config loader** — reads game config from Lua globals at startup
- **Module system** — `require()` works for splitting code across files

## Architecture

```
asobi (engine library)     — pure game backend, no Lua dependency
  └── asobi_lua (this repo) — Lua runtime: luerl + bridge modules + Docker image
       └── your game         — Lua scripts mounted at /app/game
```

Erlang developers who want to write game logic in Erlang depend on `asobi`
directly. Game developers who prefer Lua use the `asobi_lua` Docker image.

## Documentation

- [Lua Scripting Guide](guides/lua-scripting.md) — callbacks, modules, config
- [Bot AI Guide](guides/lua-bots.md) — writing bot AI scripts
- [Asobi Docs](https://github.com/widgrensit/asobi) — full engine documentation

## Erlang Dependency

For Erlang/OTP projects that want Lua scripting support as a library:

```erlang
%% rebar.config
{deps, [
    {asobi_lua, {git, "https://github.com/widgrensit/asobi_lua.git", {tag, "v0.1.0"}}}
]}.
```

## Licence

Apache-2.0
