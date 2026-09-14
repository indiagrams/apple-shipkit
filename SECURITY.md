# Security Policy

This policy covers `apple-shipkit` itself — the build, release, and CI
scaffolding that downstream consumer apps inherit. Apps derived from this
template ship their own `SECURITY.md` and own their own disclosure process;
this file is for vulnerabilities in the template's scaffolding, not in any
particular fork built on top of it.

## Push-time secret scanning

`ci/check-push-secrets.sh` runs on the pre-push hook (via `lefthook` →
`ci/local-check.sh`) and answers a question a working-tree scan structurally
cannot: **would this push upload a configured value?**

The two are not the same, and the gap is the normal outcome of fixing a leak.
Redact a value, commit the fix, and the tree is clean while the objects behind
`HEAD` still carry it — `git push` sends objects, not the checkout. The same
holds after `filter-repo --replace-text` without `--replace-message`, after a
rebase that rewrites content but not messages, and for any ref a rewrite's
range did not reach.

So the gate scans the **publish set**: objects reachable from local refs but
not from what the remote currently advertises. It reads blobs, commit **message
bodies**, tag messages and **path names** — a key id lands in a commit subject
or a filename at least as often as in file content, and a needle derived from a
filename can appear nowhere else at all.

Two limits are deliberate and stated rather than implied:

- **Commit ident headers are not scanned.** Where a configured contact address
  is also the git identity, those headers carry it in every commit ever made,
  including every commit already pushed. Scanning them would make the gate
  permanently red over something git writes by construction, and a gate that
  cannot go green gets ignored.
- **Accepted exceptions live in `ci/push-secrets-accepted.txt`**, are printed
  with their reason on every run, and require a reason to be honoured.

`ci/test-check-push-secrets.sh` drives the real script against synthetic
repositories and is mutation-proven: restoring a blob-only scan turns the
commit-message and path-name cases red by name.

## Reporting a Vulnerability

Email: **maintainers@indiagram.com**

Do NOT open a public GitHub issue for security bugs. Public issues are for
non-security bugs and feature requests; for vulnerabilities, the email
inbox is the only supported channel.

If the issue affects a downstream consumer app derived from this template
(and not the template itself), please report to that app's maintainers
instead — see "Out of Scope" below.

A useful report includes:

- A reproduction recipe — the exact commands or steps that trigger the
  issue.
- The affected file path or script (`ci/local-check.sh`, the `Fastfile`,
  a workflow under `.github/workflows/`, etc.).
- The impact you observed — what could an attacker do, on which surface.

Keep it short. This is guidance, not a gating questionnaire.

## Response

We aim to acknowledge new reports within ~7 days — same response window as
[`CONTRIBUTING.md`](CONTRIBUTING.md) and [`docs/PRINCIPLES.md`](docs/PRINCIPLES.md)
#23. Acknowledgement, not resolution: the first reply confirms we have the
report and are looking at it. Fix and release follow on their own timeline.

We follow a 90-day coordinated-disclosure window. We target a fix and a
release within 90 days of the initial report. After that window, the
reporter is free to publish their findings regardless of the fix status.

## In Scope

This policy covers the template scaffolding itself:

- Build configuration: `app/project.yml`, `Brewfile`, `Gemfile`, `Makefile`,
  `lefthook.yml`.
- CI workflows: `.github/workflows/`, the 3 PR jobs (`app (iOS device)`,
  `app (iOS Simulator)`, `app (macOS)`).
- Release scripts: `bin/`, `ci/`, `fastlane/` — including
  `ci/local-check.sh`, `ci/local-release-check.sh`, `ci/lib/*.sh`, the
  fastlane `Fastfile`, and helper tools.
- The stub `HelloApp` (iOS + macOS), insofar as it exercises the
  build/release pipeline. Bugs in the stub that demonstrate a flaw in the
  template's scaffolding count; bugs in features a forker has added on top
  of the stub do not.

## Out of Scope

Three categories of report belong elsewhere:

- **Consumer apps derived from this template.** If you found a vulnerability
  in an app built on top of this template, report it to that project's
  maintainers — they own their own `SECURITY.md`. We do not have visibility
  into how the template has been customized downstream.
- **Third-party dependencies.** Vulnerabilities in XcodeGen, fastlane,
  lefthook, GitHub Actions, or any other tool this template invokes should
  be reported upstream to the owning project. We track Dependabot bumps for
  `.github/workflows/` automatically (`docs/PRINCIPLES.md` #15) but we are
  not the right inbox for upstream issues.
- **Apple-platform vulnerabilities.** Bugs in iOS, macOS, Xcode, the
  Simulator, codesign, App Store Connect, or any first-party Apple service
  go to Apple's product security team — see
  https://security.apple.com.

## Supported Versions

This template is currently pre-1.0 and private. There is no formal support
window yet. Vulnerabilities are still in scope under this policy and will
be triaged on a best-effort basis.

Once `v1.0.0` is tagged and the repo is flipped public (planned for the M5
milestone), this policy will apply to the latest released version of the
template. Older tagged versions may receive fixes at maintainer discretion;
upgrade to the latest is the supported path.
