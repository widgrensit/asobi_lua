<p align="center">
  <img alt="asobi" src="https://raw.githubusercontent.com/widgrensit/asobi/main/docs/media/logo.png" height="96">
</p>

# This repository is retired

**The Lua runtime now lives in [widgrensit/asobi](https://github.com/widgrensit/asobi).**
Everything that used to be here - the `game.*` API, hot-reload, the sandbox, bots,
script validation, the Lua match and world bridges - moved into `asobi` itself and
is developed there. This repository holds no Erlang source any more.

**Your Lua game code is unaffected.** `match.lua`, `world.lua`, `config.lua` and
the `game.*` API are unchanged. Nothing to rewrite, nothing to rename.

## The Docker image was renamed

```
    old:  ghcr.io/widgrensit/asobi_lua
    new:  ghcr.io/widgrensit/asobi
```

**`ghcr.io/widgrensit/asobi_lua` is no longer rebuilt.** Tags already published
keep working and are not going away, but they receive no fixes - including
security fixes. The last one was built from `asobi` v0.71.0.

Change the image name in your compose file or manifest. Nothing else changes:
same tags, same ports, same environment variables. The image contents are the
same too - the game backend, the Lua runtime and the operator console. The Lua
runtime stopped being a separate application, so the old name described a part
rather than the whole.

New and existing self-hosters should follow
[asobi's self-hosting guide](https://github.com/widgrensit/asobi/blob/main/guides/self-hosting.md),
which covers the rename.

## Where to go

| For | Go to |
| --- | --- |
| Bugs and feature requests | [widgrensit/asobi issues](https://github.com/widgrensit/asobi/issues) |
| Security reports | [asobi security advisories](https://github.com/widgrensit/asobi/security/advisories/new) (never a public issue) |
| Lua scripting docs | [asobi guides](https://github.com/widgrensit/asobi/tree/main/guides) and [asobi.dev/docs](https://asobi.dev/docs) |
| Questions | [Discord](https://discord.gg/vYSfYYyXpu) |

This repository is archived and read-only. Its issues stay readable - they are
the record behind a lot of these decisions - and `docs/adr/` keeps the two
architecture decisions that were made here and nowhere else.

The guides that used to sit in this repo have been removed rather than left to
rot: they were older, shorter forks of the ones in `asobi`, and they still
taught the retired image. Use
[asobi's guides](https://github.com/widgrensit/asobi/tree/main/guides).
