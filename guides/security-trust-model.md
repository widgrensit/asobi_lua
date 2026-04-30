# Trust model

asobi_lua treats the mounted `/app/game` Lua scripts as **trusted** in
the same sense your `/app/bin/asobi_lua` binary is trusted: you control
what files end up there. The sandbox protects against incidental
scripting bugs (infinite loops, missed nil checks, atom exhaustion via
untrusted player input) and makes it harder for a *compromised*
dependency or `require`'d module to escape. It is not a defence against
a deliberate, all-Erlang-aware adversary with the ability to write
`/app/game/match.lua`.

## Verified negative results

These are properties prior security audits looked at and confirmed
hold. Documented here so future readers don't re-derive them.

### `setmetatable(_G, ...)` and `setmetatable(os, ...)` are still allowed

The strip pass calls `set_table_keys` with `nil`, which Luerl's
`set_table_key_key/4` *erases* the entry from the underlying ttdict —
the key becomes truly absent, not "set to nil". A subsequent `__index`
metatable on `os` (or `_G`) would intercept lookups for the absent
keys. However, `__index` can only return values that exist in the
script's reach, and the actual Erlang function references for
`os.execute`, `os.exit`, etc. are stored exclusively inside the os
table dict that was just erased. Once erased there is no Lua-reachable
path to those function references — they are not stored elsewhere in
the Luerl state. So metatable manipulation cannot recover stripped
functions.

### `_ASOBI_LOADED` is reachable via `_G._ASOBI_LOADED`

The require cache is installed as a global, fully visible to Lua. A
script can iterate it, mutate it, delete entries. There's no privilege
boundary inside a single Luerl state, so this is by design and
acceptable. Cross-match isolation comes from each match having its own
state; a script that clobbers its own cache only DoSes itself. The internal
`lookup_loaded` helper in `asobi_lua_loader` handles a clobbered
cache cleanly rather than crashing with `case_clause`.

### Atom-table inflation via `terrain_provider`

A Lua script that returns `{ module = "<some_atom>", ... }` from
`terrain_provider/1` cannot inflate the atom table — the bridge uses
`binary_to_existing_atom/1`. As of the F-* hardening pass the bridge
also requires the target module to be on an explicit allowlist
(`asobi_terrain_flat`, `asobi_terrain_perlin` by default; configurable
via `application:get_env(asobi_lua, terrain_providers, ...)`) so a
script that names an unrelated loaded module (`gen_server`, `rpc`,
etc.) is rejected with a `terrain_provider_not_allowed` warning.
