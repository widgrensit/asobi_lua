#!/bin/sh
# Says the image was renamed, then runs the node.
#
# ghcr.io/widgrensit/asobi_lua is the old name for what is now
# ghcr.io/widgrensit/asobi. This image stops being rebuilt after this release,
# so anything still pulling it silently stops receiving fixes - and a tag that
# quietly stops moving is the worst way to retire a name. Say it in the logs of
# every start, where an operator will actually meet it.
#
# Existing tags keep working and are never deleted. Nothing breaks today.
set -e

printf '\n' >&2
printf '========================================================================\n' >&2
printf ' ghcr.io/widgrensit/asobi_lua has been renamed.\n' >&2
printf '\n' >&2
printf '   Use:  ghcr.io/widgrensit/asobi\n' >&2
printf '\n' >&2
printf ' Same image contents: the game backend, the Lua runtime and the\n' >&2
printf ' operator console. The Lua runtime stopped being a separate\n' >&2
printf ' application, so the old name described a part rather than the whole.\n' >&2
printf '\n' >&2
printf ' Change the image name in your compose file or manifest. Nothing else\n' >&2
printf ' changes - same tags, same ports, same environment variables.\n' >&2
printf '\n' >&2
printf ' THIS IMAGE IS NO LONGER REBUILT. Tags already published keep working\n' >&2
printf ' and are not going away, but they will not receive fixes.\n' >&2
printf '========================================================================\n' >&2
printf '\n' >&2

exec "$@"
