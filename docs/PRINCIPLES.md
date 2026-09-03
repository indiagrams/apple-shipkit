# Principles

How `apple-shipkit` is run. The short version: opinionated where it
matters (build, release, security), permissive where it doesn't (your app
code, your icons, your copy).

These principles are how we evaluate PRs. If a change conflicts with one of
them, the PR doesn't land — but the principle is also negotiable: if you can
articulate why one of these is wrong for your contribution, open an issue
first and let's talk.

## Quality gates

1. **Every PR runs CI.** Eight required checks: swiftlint + swiftformat
   plus six matrix cells (3 XcodeGen — `app (iOS device)`,
   `app (iOS Simulator)`, `app (macOS)` — plus 3 Tuist parity —
   `app (Tuist iOS device)`, `app (Tuist iOS Simulator)`,
   `app (Tuist macOS)`) — must be green before merge. Branch protection
   enforces this for everyone, including maintainers.
2. **No direct pushes to `main`.** Even one-line fixes go through a PR. The
   pre-push hook (`lefthook` → `ci/local-check.sh --fast`) catches breakage
   before it reaches GitHub.
3. **Squash-merge only, linear history.** No merge commits. No rebase merges.
   `git log` reads like a sequence of features, not a tangle.
4. **The stub builds green on every PR.** `make check` is the floor. A PR
   that breaks the `HelloApp` stub does not land — even if it's "just" docs;
   even if it's "just" a script rename.
5. **Shared CI helpers are SHA-pinned.** Files in `ci/lib/` are byte-identical
   across this template and downstream consumer projects that derive from it.
   `ci/lib/SHA256SUMS` is checked on every run; drift is a CI failure, not a
   warning.
6. **The release pipeline is continuously validated by a public downstream.**
   [`indiagrams/ios-macos-smoketest`](https://github.com/indiagrams/ios-macos-smoketest)
   runs a **single weekly canary sweep** to TestFlight against this template's
   signing pattern. Apple-shipkit's `canary-trigger.yml` fires once on
   Saturdays 07:00 UTC and orchestrates three sequential cells against the
   smoketest: CI-mode xcodegen (`release.yml`), CI-mode tuist (`release.yml`),
   and local-mode (`canary-local-mode.yml`, which internally iterates both
   generators). As of v1.6, all three exercise the **same** mint-fresh-cert-
   then-revoke code path — the architectural distinction between "CI mode =
   match-based" and "local mode = sigh-based" from v1.5 is gone. They remain
   as three cells to give the smoketest dashboard separate signals per
   shipping path.
   Because Apple's signing infra (certs, profiles, `timestamp.apple.com`,
   ASC ingestion) and the fastlane / pilot stacks drift independently
   of this template, the smoketest catches rot before forkers do.
   Patterns + fixes there land back here in PRs that cite the failing
   smoketest run. See [`docs/CONTINUOUS-VALIDATION.md`](CONTINUOUS-VALIDATION.md)
   for the catalog of canonical failure modes (currently 16) the smoketest
   has surfaced.

## Documentation

7. **Every script has a header comment** explaining *why* it exists. Not just
   *what* — the *what* is in the code. The *why* is the constraint, the
   incident, the gotcha that justified writing the script in the first place.
8. **README answers "what / why / how" within the first 50 lines.** Beyond
   that is reference material. A reader should know if this template is for
   them without scrolling.
9. **Non-obvious patterns get a "Why this exists" section.** The macOS
   app-sandbox re-sign hack, the cert SHA-1 pinning, the PlistBuddy bool
   quirk — every one of these is documented in source comments AND in the
   README. If you remove one of these, you remove its explanation too.
10. **CHANGELOG updated in the same PR as the change.** Not retroactively
   batched at release time. We follow [Keep a Changelog](https://keepachangelog.com/).

## Stability

11. **Semver applies to template structure.** This template is a piece of
    software with an API: directory layout, script names, Makefile targets,
    bundle ID conventions. Renaming `bin/setup-github.sh` is a breaking
    change → major version bump.
12. **Deprecate before removing.** If a target or script goes away, it gets a
    deprecation note in CHANGELOG one minor release before deletion. Users
    of `gh repo create --template` should be able to skim the CHANGELOG and
    know what to update.
13. **Personalization and migration output a buildable project.** Always.
    If `bin/rename.sh` or `bin/migrate-identity.rb` produces a project that
    can't `make check` green, that's a P0 bug.

## Security

14. **No secrets in any committed file.** `.gitignore` blocks `.env*`,
    `*.pem`, `*.p8`, `*.mobileprovision`, etc. Pre-release audits sweep for
    leaks. If you're adding a new secret-shaped file, add the pattern to
    `.gitignore` in the same PR.
15. **Vulnerability disclosure is private.** Don't open public issues for
    security bugs. Email the address in `SECURITY.md`. We follow a 90-day
    coordinated-disclosure window.
16. **GitHub Actions versions auto-bump.** Dependabot is on for the
    `.github/workflows/` files. We don't manually pin OSS infrastructure.
17. **2FA required for maintainers.** Org-level enforcement.

## Community

18. **CONTRIBUTING.md tells you exactly what's expected.** Fork → branch →
    `make check` → PR. No surprises, no implicit norms, no "I assumed you'd
    know to..." — if it's expected, it's written down.
19. **Code of Conduct: Contributor Covenant 2.1, verbatim.** No edits. No
    custom carve-outs. The standard is the standard.
20. **Issue templates have required fields.** Bug reports without
    reproduction steps and feature requests without a use case get gentle
    redirection to the template, not closure. The templates exist to help
    you write a useful issue, not to gate participation.
21. **Every PR has a test plan.** Even docs-only PRs. Even single-character
    typo fixes. "Verified the typo is fixed" is a valid test plan. The point
    is the muscle memory.

## Licensing

22. **MIT, single-licensed.** No dual-licensing. No CLA. Inbound = outbound:
    contributors retain copyright on their changes; the project licenses
    everything under MIT.
23. **Third-party code is vendored with its `LICENSE` preserved.** `ci/lib/`
    is the canonical example. If we ever vendor anything else (a GitHub
    Action, a Ruby snippet, a Swift utility), it ships with its own
    license file, untouched.

## Maintenance

24. **Issues and PRs get a first response within ~7 days.** Even "looking
    at it" or "this isn't the right fit, here's why" beats silence. We don't
    promise resolution timelines — but we do promise acknowledgement.
25. **The "Use this template" flow is a tested invariant.** Smoke-tested
    against a fresh clone before each release. If the template can't be
    materialized into a working repo, no release happens.

---

## Tone

We aim for a small, useful template. We say no to features that fit a
specific organizational use case but not the broader iOS/macOS world. We say
yes to fixes for the gotchas hiding in `xcodebuild`, `fastlane deliver`,
`actool`, and `codesign` — because someone hit them, debugged them, and
shouldn't have to do that again.

If you're considering a contribution, ask:

- Does this fix a sharp edge a stranger would hit?
- Does it preserve the "5-minute clone-to-first-build" promise?
- Does it generalize, or is it specific to your project?

If the answer to all three is yes, open a PR. If you're unsure, open an issue first.
