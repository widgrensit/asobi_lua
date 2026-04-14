# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in `asobi_lua`, please report it
**privately** so we can fix it before it is publicly disclosed.

**Do not open a public GitHub issue for security issues.**

### How to report

Either of these channels work:

- **GitHub Security Advisory (preferred):**
  [Report privately](https://github.com/widgrensit/asobi_lua/security/advisories/new)
- **Email:** security@asobi.dev

### What to expect

- Acknowledgement within **48 hours**
- Initial assessment within **7 days**
- Coordinated disclosure timeline agreed with you
- Credit in the security advisory if you want it

## Supported versions

| Version | Supported |
|---------|-----------|
| latest stable | ✅ |
| older releases | ❌ — please upgrade |

## Scope

**In scope:**
- The `asobi_lua` Erlang/OTP runtime (this repository)
- The Luerl sandbox configuration shipped with this runtime

**Out of scope:**
- The hosted asobi.dev SaaS — see https://asobi.dev/security
- The `asobi` library — report to https://github.com/widgrensit/asobi/security
- Third-party dependencies (Luerl etc.) — please report upstream
