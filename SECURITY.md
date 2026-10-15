# Security Policy

## Reporting a vulnerability

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/steven-dinh/relay/security/advisories/new). Include the affected Relay tag or commit, Studio build, a minimal reproduction in your own place, and the security impact. Do not include secrets or real-player data. We aim to acknowledge reports within seven calendar days on a best-effort basis; we cannot guarantee a resolution date.

We coordinate disclosure timing with the reporter. A published advisory will describe affected versions, available fixes or mitigations, applicable upgrade guidance, and credit as agreed with the reporter.

## Maintenance

Relay maintains the latest patch of the newest released minor series. Older versions should upgrade; there is no fixed LTS or backport window. `main` is the development source.

Compatible fixes ship in patch releases. Before 1.0, incompatible API or wire changes use a minor release with migration notes. Mixed-version support is limited to explicitly verified pairs with identical descriptors and topology. Ordinary removals are announced at least one release ahead; an urgent security correction may bypass that notice, with the reason and migration documented. Releases ship when fixes are verified, with no calendar schedule and under Relay's existing review and verification gates.
