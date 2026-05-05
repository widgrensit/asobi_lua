# ADR 0000: Record architecture decisions

Date: 2026-05-05

## Status

Accepted.

## Context

asobi_lua hosts user-supplied Lua running inside Luerl. Decisions about
sandboxing, timeouts, hot-reload, bridge module shape, and which calls
get spawn-isolated have safety implications that are easy to forget and
expensive to revisit. We need a record.

## Decision

Record significant architecture decisions as numbered markdown files in
`docs/adr/`. One file per decision. Filename: `NNNN-short-slug.md`.

Same template as the `asobi` repo (Michael Nygard ADR style):

- **Title** — `ADR NNNN: short imperative phrase`
- **Date** — `YYYY-MM-DD`
- **Status** — `Proposed` | `Accepted` | `Superseded by ADR NNNN` | `Deprecated`
- **Context** — what's true now that motivates this decision
- **Decision** — the choice, in one or two short paragraphs
- **Consequences** — what this enables, what it costs
- **Alternatives considered** — options ruled out, with one-line rationale

ADR-worthy things in asobi_lua:

- Changes to which Luerl entry points are exposed or restricted
- Changes to the sandbox or timeout/heap budgets
- New behaviour-bridge modules or callback shapes
- Decisions that trade safety for performance

Not ADR-worthy: bug fixes, renames, pure refactors.

## Consequences

- Future readers can recover the *why* behind sandbox + timeout choices.
- Forces articulating which alternative was rejected and on what grounds.

## Alternatives considered

- **Inline comments** — drift, fragmented, easy to miss.
- **Wiki / external doc** — separates from the code; ADRs in-repo travel
  with the branch.
