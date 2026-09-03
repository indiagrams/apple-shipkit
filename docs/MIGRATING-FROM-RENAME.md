# Migrating a renamed fork onto the config-based identity

> **This document is for a fork created before the identity work landed.** You ran
> `bin/rename.sh` at fork time, so your project, your schemes, your targets, your `@main`
> struct, your entitlements files and your test classes are all named after *your app*
> rather than after the constant `App`. This is the in-place path back onto the template's
> structure.
>
> **It is not for a fresh fork.** A fork created after that work already ships the constant
> structure and sets its four values in `app/Identity.xcconfig`. There is nothing to
> migrate. If `app/Identity.xcconfig` is already in your tree, stop reading — the command
> below will tell you the same thing and exit 0.

The whole migration is one command:

```bash
ruby bin/migrate-identity.rb --dry-run   # detect and report; writes nothing
ruby bin/migrate-identity.rb             # do it
```

> **Path note.** In a fork that has adopted this from the template the command is at
> `bin/migrate-identity.rb`. This repository carries it at `bin/migrate-identity.rb`,
> which is the path used throughout this document. Adjust to match the copy you have; the
> two are the same file.

The rest of this document explains what the command does, the one change it makes that you
cannot take back, and what is still yours to do after it exits 0.

---

## The risk you're avoiding

A renamed fork derives its *structure* from its *name*. The template derives nothing from
its name: the project is `App.xcodeproj`, the entry point is `AppMain`, the entitlements are
`App.entitlements`, and the four things that actually vary between forks — bundle id,
product name, display name, copyright — live in `app/Identity.xcconfig` as values.

While those two models disagree, every upstream change you adopt has to be re-spelled into
your names by hand, and every name-derived path in the release pipeline is one rename away
from pointing at something that does not exist.

The concrete symptom this repository hit and recorded: `make ship` performed a full signed
archive and a full export, and then died at

```
IPA missing at build/<name>-<version>.ipa
```

because a Fastfile pattern derived from one name no longer matched the artefact the release
script had written under another. Nothing was wrong with the build. Two files simply
disagreed about what the app was called, and neither of them was the app.

Migrating removes the disagreement by removing the derivation.

---

## Before you migrate — read this if your app is live on the App Store

**The migration changes the filename of your built app bundle and the name of the
executable inside it.** This is the one change in the migration that is not reversible by
the command, and it is the reason this section exists.

### What was measured

A throwaway fork was created from this template's pre-rename tree, renamed by
`bin/rename.sh` itself, then migrated. Both platforms were built before and after, and the
values below were read off the **built** `Info.plist` with `plutil`, not out of a manifest:

| | before the migration | after the migration |
|---|---|---|
| iOS bundle | `<N>-iOS.app` | `<N>.app` |
| iOS `CFBundleExecutable` | `<N>-iOS` | `<N>` |
| macOS bundle | `<N>-macOS.app` | `<N>.app` |
| macOS `CFBundleExecutable` | `<N>-macOS` | `<N>` |
| `CFBundleIdentifier`, both platforms | `com.example.<n>` | `com.example.<n>` — **unchanged** |

`<N>` is the name you passed to `bin/rename.sh`.

**Why it happens.** Nothing in a pre-rename fork assigns `PRODUCT_NAME`, so Xcode defaults
it to each target's own name — platform suffix included — and the fork resolves **two**
values, one per platform. A migrated tree assigns `PRODUCT_NAME = $(APP_PRODUCT_NAME)` on
the two app targets and resolves **one** value on both. Two values collapse to one, and the
built filenames follow.

**There is no values-only option.** The command does not offer a mode that writes
`app/Identity.xcconfig` and leaves the structure alone. `app/Identity.xcconfig` holds one
`APP_PRODUCT_NAME` for both platforms by design, so a migration that preserved both old
`PRODUCT_NAME` values would have to keep deriving them from the target names — which is the
thing being removed.

**Your App Store Connect record is not affected.** That record is keyed on the bundle
identifier, and `CFBundleIdentifier` is carried across unchanged and asserted at the built
artefact, as the table above shows.

### What you are being asked to do

**If your app is already live on the App Store, verify that the executable-name change is acceptable for your app before you migrate.**

This template has **not** verified how Apple treats a changed executable name on an existing
listing, and it makes no claim either way — not from memory, not from a remembered
documentation page, not hedged. That question is yours and Apple's, and this document
deliberately does not answer it on your behalf.

Verify first. Checking costs you one question before you start; finding out at upload costs
you a release, on an app that is already in front of users.

If you have never shipped this app to the App Store, none of the above applies to you and
you can migrate freely.

### Downstream names that move with it

The built name is not the only thing derived from `PRODUCT_NAME`. Expect to review:

- `IPA_NAME_PATTERN` and `PKG_NAME_PATTERN` in `fastlane/Fastfile`, which build an artefact
  filename out of a name.
- `ci/local-release-check.sh`, which writes `build/<name>-<version>.ipa` and
  `build/<name>-<version>.pkg` and archives under a name-derived path.
- `TEST_HOST` and `BUNDLE_LOADER` on the unit-test bundles. **The command rewrites these for
  you** — see "What the command changes" below — because it is the migration's own
  `PRODUCT_NAME` rewrite that would otherwise break them.
- Screenshot scripts that locate the built `.app` by name. `bin/take-readme-screenshots.sh`
  searches for `"$SCHEME_IOS.app"`; after the migration your iOS scheme is `App-iOS` while
  the built bundle is `<N>.app`, so that search finds nothing.

---

## Prerequisites

- **A clean working tree.** The command refuses otherwise, with exit 4 and a count of the
  offending entries. That refusal is not fussiness: any mid-flight failure rolls the tree
  back with `git reset --hard`, which would destroy uncommitted work. Untracked files count
  too, because the rollback's `git clean` removes them.
- **A git repository, on a branch you can reset.** The command wants to be on `main`; if the
  repository has a `main` and you are on something else it refuses (exit 4) so that the
  rollback restores the branch you expect. If there is no `main` at all it says so and
  proceeds.
- **`xcodegen` on `PATH`.** The command regenerates the project after the structure moves.
- **`xcodebuild`** — that is, Xcode. The fork's current identity is read from
  `xcodebuild -showBuildSettings`, because that is the only source that reports what the
  build actually resolves. There is no second source for it.
- **A generated project already on disk**: `app/<N>.xcodeproj`, with a `project.pbxproj`
  inside it. This is easy to miss because the project is gitignored and a fresh clone has
  none. Run `cd app && xcodegen generate` first, or the command exits 4 and tells you to.
- **Both app schemes**, `<N>-iOS` and `<N>-macOS`, each resolving exactly one target in its
  build action. A scheme whose build action grew a second target is refused rather than
  guessed at.
- **The two files the command ships with**: `bin/preflight-identity.rb` and
  `bin/lib/xcconfig.rb`. A pre-rename fork has **neither** — both are later than the fork you
  are migrating — and the command refuses by name if the gate is missing. Step 1 below
  copies them.
- **Ruby.** Any current Ruby. Note that `/usr/bin/ruby` on macOS is 2.6.10; the command is
  developed and tested under 3.3 and 4.0.

---

## Step-by-step walkthrough

### 1. Copy the command and the two files it ships with

The migration is not a standalone script. It `require`s the one xcconfig reader, and it runs
the identity gate against the migrated tree before it releases its rollback. Both resolve
next to the command, not out of the tree being migrated.

```bash
git remote add upstream https://github.com/indiagrams/apple-shipkit.git   # if you have none
git fetch upstream
git checkout upstream/main -- bin/migrate-identity.rb bin/preflight-identity.rb bin/lib/xcconfig.rb
git commit -m "chore: adopt the identity migration command"
```

Use `git checkout upstream/main -- <path>`, not `git show upstream/main:<path> > <path>` —
the redirect form silently drops the executable bit.

### 2. Start from a clean tree, on a branch you can reset

```bash
git status --short     # must print nothing
git switch -c migrate-identity   # optional, but the rollback resets HARD
```

### 3. Dry-run first

```bash
ruby bin/migrate-identity.rb --dry-run
```

It writes nothing, and it prints what it found and what it would do:

```
MIGRATE-IDENTITY: state: never-migrated — none of the four migration signals is present in /path/to/fork
MIGRATE-IDENTITY: detected structural token: <N>, read 3 independent way(s):
MIGRATE-IDENTITY:   app/project.yml name: => <N>
MIGRATE-IDENTITY:   app/Shared/<N>.swift struct <N>Main => <N>
MIGRATE-IDENTITY:   app/<N>.xcodeproj => <N>
MIGRATE-IDENTITY: planned transformation:
MIGRATE-IDENTITY:   1. write app/Identity.xcconfig with BUNDLE_ID, APP_PRODUCT_NAME, DISPLAY_NAME, COPYRIGHT, ...
...
MIGRATE-IDENTITY: KNOWN BREAKING CHANGE: the built executable's filename changes, ...
MIGRATE-IDENTITY: --dry-run: nothing was written.
```

If the three derivations of your fork's name disagree, the command stops here with exit 2
and prints all three. That is a tree it will not guess about: migrating one of three
opinions would rename the other two to something they never were.

### 4. Run it

```bash
ruby bin/migrate-identity.rb
```

It narrates every step and closes with a report. Abridged, from a real run:

```
MIGRATE-IDENTITY: ==== PRODUCT_NAME COLLAPSES TO ONE VALUE ====
MIGRATE-IDENTITY:   before, iOS:   PRODUCT_NAME = <N>-iOS
MIGRATE-IDENTITY:   before, macOS: PRODUCT_NAME = <N>-macOS
MIGRATE-IDENTITY:   after, both:   APP_PRODUCT_NAME = <N>
MIGRATE-IDENTITY: wrote .../app/Identity.xcconfig and verified all four values by reading them back
MIGRATE-IDENTITY: moved the Apple Team ID into .../app/Local.xcconfig and removed it from both manifests
MIGRATE-IDENTITY: renamed app/Shared/<N>.swift -> app/Shared/App.swift (git mv, history preserved)
...
MIGRATE-IDENTITY: ==== MIGRATION COMPLETE ====
...
MIGRATE-IDENTITY: ==== ONE BREAKING CHANGE, AND IT IS NOT REVERSIBLE BY THIS COMMAND ====
MIGRATE-IDENTITY: next: review the diff (git diff HEAD, and git diff --cached -M for the renames),
MIGRATE-IDENTITY:   build both platforms, then commit. To undo everything this run did:
MIGRATE-IDENTITY:   git reset --hard HEAD && git clean -fd
```

The command does not commit. It leaves the renames staged (that is what `git mv` does) and
everything else in the working tree, so you review before anything is permanent.

### 5. `--root PATH`, and why you almost certainly do not want it

`--root PATH` points the command at a tree other than the one it lives in. It exists so the
test suite can drive it against throwaway fixtures. Whenever it is given, the command prints
a three-line banner on stderr *before doing any work*:

```
MIGRATE-IDENTITY: ==== ROOT OVERRIDE IN EFFECT (--root) ====
MIGRATE-IDENTITY: default root /path/that/was/skipped was NOT inspected
MIGRATE-IDENTITY: inspecting override /path/that/was/taken instead
```

so a fixture run can never be mistaken for a real one in a log. A default run prints no
banner at all. Migrate your own fork by running the command from inside it, with no flags.

### 6. What the command already did to the rest of your fork

**This used to be a manual step. It is not one any more, and this section says exactly what
changed so you can check the diff rather than trust the claim.**

`bin/rename.sh` substituted your name across the whole tree. The migration rewrites the files
under `app/`, `.gitignore`, and **every other tracked file that names your generated project
or one of your app schemes** — so `make check`, `make ship` and `make screenshots` still run
the moment the command exits.

Two token classes are rewritten, both anchored, and nothing else:

| It was | It is now | Where that matters |
|---|---|---|
| `<N>.xcodeproj`, `<N>.xcworkspace` | `App.xcodeproj`, `App.xcworkspace` | `-project`, `project(…)`, `--workspace` |
| `<N>-iOS`, `<N>-macOS` | `App-iOS`, `App-macOS` | `-scheme`, `scheme(…)`, archive names |

A **bare** `<N>` is never rewritten, anywhere, by anything. Your name is still your name in
prose, in `README.md`, in your app's own strings. Only the shape around an occurrence says
whether it is a project path or a product name, and only the first is structure.

**The set is enumerated from your tree, not from a list inside the command.** It runs
`git ls-files`, applies the two patterns, and reports what it rewrote with a per-file count:

```
MIGRATE-IDENTITY: entry points, outside app/, pointed at the new project and schemes: 14 file(s), 60 substitution(s)
MIGRATE-IDENTITY:   ci/local-check.sh  (project-path x3, scheme-name x3)
MIGRATE-IDENTITY:   ci/local-release-check.sh  (project-path x3, scheme-name x4)
MIGRATE-IDENTITY:   fastlane/Snapfile  (project-path x1, scheme-name x1)
…
```

That transcript is from a real fork. Yours will differ, because the count is a measurement of
your tree rather than a number written into the command.

**Untracked and gitignored files are not reached.** That is deliberate: the rollback restores
tracked files with `git reset --hard`, and a file the migration could write but the rollback
could not restore would be a hole in its all-or-nothing guarantee.

#### What it did NOT rewrite, and why it tells you so by name

At the end of the run the command lists every tracked file outside `app/` that still mentions
your name on a line that also names a project, a scheme or a target:

```
MIGRATE-IDENTITY: STILL NAMING <N> BESIDE A PROJECT, A SCHEME OR A TARGET — not rewritten, and named
MIGRATE-IDENTITY: here rather than left for you to find in a red build:
MIGRATE-IDENTITY:   .github/workflows/pr.yml:247,248,268,269,285,286  — the token is not adjacent to a project path or a scheme suffix here
MIGRATE-IDENTITY:   CHANGELOG.md:54,101,184,186  — excluded on purpose: historical record, and not an entry point
```

Two kinds end up in that list.

- **`CHANGELOG.md` is excluded on purpose.** It is historical record. On a real fork its
  occurrences sit inside a quoted CI failure message from a dated entry and inside prose
  describing what the upstream template used to be called; rewriting either would falsify a
  line that was true when it was written. Nothing reads `CHANGELOG.md` to find a project.
- **Some files build a project path or a scheme name out of a value.** GitHub Actions writes
  `app/${{ vars.APP_NAME || '<N>' }}.xcodeproj`; `fastlane/Fastfile` writes
  `IOS_SCHEME = "#{APP_NAME}-iOS"`. In both, your name is a *fallback value* that some other
  expression turns into a path. The command does not parse Actions expressions or Ruby, so it
  names them instead of guessing at them.

Close those two the way you would have closed the whole list before:

1. **Adopt the template's current copies.** They use the constant `App` and the repository
   variable, which is what makes them stop needing per-fork edits forever. This is the return
   on migrating.
2. **Or set the repository variable `APP_NAME` to `App`**, which fixes `pr.yml` without
   touching the file, and edit `fastlane/Fastfile`'s `APP_NAME` fallback.

Expect a few half-rewritten sentences in prose, and they are listed for you too. A line like
`Tuist sanitizes <N>-iOS → <N>_iOS` becomes `Tuist sanitizes App-iOS → <N>_iOS`, because the
underscore form is not one of the two classes. It is a comment; nothing depends on it.

#### One thing that is still yours to add

The template's `app/project.yml` runs the identity gate before every generate.

```yaml
options:
  preGenCommand: ruby ../bin/preflight-identity.rb
```

The migration deliberately does **not** add that line, because a fork that has not yet copied
`bin/preflight-identity.rb` across would have a project that can never be generated. Add it
yourself once step 1 is committed.

### 7. Review and commit

```bash
git diff HEAD                 # the content changes
git diff --cached -M --name-status   # the five renames, as the migration left them
```

The rename lines should read `R100`. If you see an `A`/`D` pair instead, history was not
preserved and something went wrong — reset and report it.

---

## What the command changes

Grouped by kind. Inside `app/` the list of sites is frozen in the command. Outside it, the
set is enumerated from your tree at run time with `git ls-files` and two anchored patterns
(step 6). Either way there is no glob that writes and no whole-tree sweep: a bare `<N>` is
never rewritten anywhere.

**Five history-preserving `git mv` renames**

| From | To |
|---|---|
| `app/Shared/<N>.swift` | `app/Shared/App.swift` |
| `app/iOS/<N>.entitlements` | `app/iOS/App.entitlements` |
| `app/macOS/<N>.entitlements` | `app/macOS/App.entitlements` |
| `app/Tests/<N>Tests.swift` | `app/Tests/AppTests.swift` |
| `app/MacOSTests/<N>MacOSTests.swift` | `app/MacOSTests/AppMacOSTests.swift` |

`git mv`, not copy-and-delete: `git log --follow` still reaches the history of every one of
them, and the diff stays reviewable.

**Three declarations, moved in the same operation as the files that hold them**

- `struct <N>Main: App` becomes `struct AppMain: App`
- `final class <N>Tests` becomes `final class AppTests`
- `final class <N>MacOSTests` becomes `final class AppMacOSTests`

**Both manifests, rewired so identity is a `$(VAR)` reference and never a literal**

- `app/project.yml` — `name:`, the six target keys, the scheme keys, `TEST_TARGET_NAME`,
  `CODE_SIGN_ENTITLEMENTS`, a `configFiles:` block pointing at `Identity.xcconfig`, and a
  per-target `PRODUCT_NAME = $(APP_PRODUCT_NAME)` on the **two app targets only** — never a
  project-level one, which leaks into every target including the test bundles.
- `app/Project.swift` — the Tuist equivalent, including `productName:` and
  `.settings(configurations:)`, so both generators keep agreeing.
- **`TEST_HOST` and `BUNDLE_LOADER` on every unit-test target.** These are rewritten because
  the per-target `PRODUCT_NAME` above would otherwise break them: XcodeGen bakes the host
  *target name* into `TEST_HOST` when it generates, while `PRODUCT_NAME` now resolves at
  build time, so `xcodebuild test` would fail with "Could not find test host" against a path
  nothing builds at. UI-test bundles are left alone — they use `TEST_TARGET_NAME`, which is a
  target name and is correct as it stands.

**`.gitignore`** — `app/<N>.xcodeproj` and `app/<N>.xcworkspace` become `app/App.xcodeproj`
and `app/App.xcworkspace`, so the regenerated project stays ignored rather than becoming a
generated directory in git. A row for `app/Local.xcconfig` is added if git does not already
consider that path ignored.

**A new `app/Identity.xcconfig`**, holding `BUNDLE_ID`, `APP_PRODUCT_NAME`, `DISPLAY_NAME`
and `COPYRIGHT`, read from what your build currently resolves and then read *back* through
the one parser and compared to the value the build reported. A value that does not survive
the round trip is a refusal, not a warning.

**`DEVELOPMENT_TEAM` moved to `app/Local.xcconfig`**, which is gitignored, and removed from
both manifests along with the now-false comments that described it. The write happens only
after `git check-ignore` confirms the path is ignored — asked again after the `.gitignore`
row is added — so your Apple Team ID cannot land in a tracked file.

Finally the stale `app/<N>.xcodeproj` is removed and its absence proven, `app/App.xcodeproj`
is generated, and `bin/preflight-identity.rb` is run against the migrated tree and required
to exit 0 **while the rollback is still armed**. A tree that fails its own identity gate is
restored, not shipped.

---

## What the command deliberately does NOT change

Three files are never opened for writing on any path, and their SHA-256 digests are asserted
across a migration in the test suite:

- `app/Shared/AccessibilityIdentifiers.swift`
- `app/Shared/Localizable.xcstrings`
- `app/Shared/PrivacyInfo.xcprivacy`

`app/Shared/ContentView.swift` is treated the same way, and so is any file you added.

**Why.** In a pre-rename fork, *structure* and *identity* are the same token. A reverse
sweep that rewrote every occurrence of your name to `App` would take your own choices with
it: the accessibility identifier `"<N>.title"` is a contract between your views and your UI
tests, the string-catalog key is user-visible, and `Text("<N>")` is what your running app
draws on screen. Those are yours. The migration is about the template's structure, not about
your app's content.

The command requires all three to be **present** before it starts, and refuses (exit 4) if
any is missing — because "this migration did not touch `Localizable.xcstrings`" is trivially
true of a tree that does not have one.

**`CHANGELOG.md` is never written either**, and for the same reason one level out: it is
historical record, its occurrences of your name sit inside quoted error messages and dated
entries, and nothing reads it to find a project. Its digest is asserted unchanged across a
migration in the test suite, exactly as the three above are. The command names it at the end
of the run rather than leaving you to discover it.

**And no bare `<N>` is rewritten anywhere outside `app/`.** The rewrite in step 6 requires
your name to be followed immediately by `.xcodeproj`, `.xcworkspace`, `-iOS` or `-macOS`.
`README.md` still says your name; so does your `SECURITY.md`, and so does every sentence
that is about your app rather than about its project file.

One consequence to expect: comments that mention the old project or scheme survive in the
moved files. A migrated `app/Tests/AppTests.swift` keeps its `// xcodebuild test -project
app/<N>.xcodeproj -scheme <N>-iOS` line. Nothing breaks; it is a stale comment, and it is
yours to update.

---

## When NOT to run it

The command detects three states and exits distinguishably on each. It never exits 0
silently.

| Your tree | Exit | What it does |
|---|---|---|
| **Already fully migrated** — all four signals present and all four variables non-empty | **0** | Prints a full report naming every satisfied signal and stops. A silent exit 0 was rejected by design: it cannot be told apart from a migration that did nothing because it could not read the tree. |
| **Partially migrated** — any mixture | **3** | Refuses, naming every satisfied signal, every unsatisfied one, and any required variable that is present-but-empty. Migrating a half-migrated tree would rename things that were already renamed and leave the rest. |
| **Not a tree it understands** — no `app/project.yml`, no readable `name:`, a structural token that cannot be read the same way twice, an unresolvable `app/Identity.xcconfig`, an unreadable build-settings dump, or two platforms that disagree about a value there is only one of | **2** | Refuses, naming every value it found. |

The four signals it looks at are: `app/Identity.xcconfig` exists, `app/Shared/App.swift`
exists, `app/project.yml`'s `name:` is `App`, and `app/iOS/App.entitlements` exists.

The other two codes: **1** is a malformed argument or an unknown value for one of the fixture
knobs, and **4** is a refusal during the mutation phase — a gate in front of the mutation
(toolchain, clean tree, on `main`, a Team ID that must not be written), a must-not-touch file
that is not there, a manifest the command cannot rewire, a stale generated project that
survives its removal, a failed `git mv` or generation, or a migrated tree that fails its own
identity gate. Every exit-4 path rolls the tree back and says so.

Exit 2 and exit 3 are deliberately different codes: "this tree was never understood" must
never be readable as "this tree checked out".

## Re-running it

Safe, in the sense that it is not destructive: on an already-migrated tree it exits 0 with a
report and writes nothing. It is not a way to *re-do* a migration — a tree that is half
migrated is exit 3, and reconciling it is a manual job or a `git reset --hard` back to the
un-migrated state followed by one clean run.

---

## If something goes wrong

**Any failure after the first write rolls the entire tree back**, automatically, before the
command exits. The rollback is:

0. restore the gitignored files the command itself wrote (`app/Local.xcconfig`), from
   snapshots taken before each write — `git` cannot restore a gitignored file;
1. remove the regenerated project, if this run created one;
2. `git reset --hard HEAD`;
3. `git clean -fd`.

**`-fd`, and never `-fdx`.** The `-x` variant would also delete ignored files — your
`.bootstrap.env` and your `app/Local.xcconfig`, which hold answers and an Apple Team ID that
no failure of this command justifies destroying. Step 3 removes only files git can see as
untracked, and step 0 exists precisely because steps 2 and 3 structurally cannot reach the
ignored ones.

You will see, on stderr:

```
MIGRATE-IDENTITY: rolling back to the pre-migration state...
MIGRATE-IDENTITY: rolled back to the pre-migration state.
MIGRATE-IDENTITY FAILED: <what happened> ... Rollback outcome: restored.
```

**If the reset itself fails**, the command says so and hands the tree to you rather than
pretending:

```
MIGRATE-IDENTITY: git reset --hard HEAD failed (exit N): <git's message>
MIGRATE-IDENTITY: manual recovery required — inspect: git status; git log --oneline -5
```

and the refusal reports `Rollback outcome: manual-recovery-required`. That is the one case
where you are on your own; start with `git status` and `git log --oneline -5`, exactly as it
says.

**To undo a successful migration** you did not want, before you commit it:

```bash
git reset --hard HEAD && git clean -fd
```

That is the command's own closing advice, and it is why step 2 of the walkthrough asks for a
clean tree on a branch you can reset.

---

## Verification (what "done" looks like)

Run all of these. The first two are cheap; the rest are the ones that would have caught the
two defects this template found the hard way.

```bash
# 1. the identity gate: all four variables present and non-empty
ruby bin/preflight-identity.rb                  # expect: identity preflight ok, exit 0

# 2. and with the Team ID required, since the migration just moved it
ruby bin/preflight-identity.rb --require-team   # expect: exit 0

# 3. a real build, both platforms — not just a generate
xcodebuild build -project app/App.xcodeproj -scheme App-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project app/App.xcodeproj -scheme App-macOS \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO

# 4. read the BUILT bundle, not the manifest that was supposed to produce it
plutil -extract CFBundleIdentifier      raw -o - <built>.app/Info.plist
plutil -extract CFBundleExecutable      raw -o - <built>.app/Info.plist
plutil -extract CFBundleDisplayName     raw -o - <built>.app/Info.plist
plutil -extract NSHumanReadableCopyright raw -o - <built>.app/Info.plist
```

On macOS the plist is at `<built>.app/Contents/Info.plist`.

```bash
# 5. your own entry points, RUN rather than read
make check           # or: ci/local-check.sh --fast
```

That last one is the whole of step 6 in one command. If it resolves `app/App.xcodeproj` and
`App-iOS`, the migration pointed your tooling at the project it just created. If it names a
project that no longer exists, something in step 6's report did not land and the report will
say which file.

Step 4 is not optional and it is not paranoia. This template shipped two defects that every
file-level check was green about: a `TEST_HOST` that pointed at an app which never got built,
and an `INFOPLIST_KEY_` copyright that never reached the bundle. Both were found by reading
the built artefact. If it must be true of the app you ship, read it off the app you built.

Optional, if you keep both generator manifests: compare the
resolved build settings, `TEST_HOST`/`BUNDLE_LOADER` and the built `Info.plist` across
XcodeGen and Tuist, and exits 0 when they agree. It needs `xcodegen`, `tuist` and
`xcodebuild` all present, and it is not part of the minimum migration set.

Done looks like: preflight exits 0 both ways, both platforms build, the built bundle's
`CFBundleIdentifier` is the one you started with, and `git diff --cached -M --name-status`
shows five `R100` lines.

---

## Caveats

- **The executable-name change cannot be undone by this command.** Re-read the section above
  before you ship, not after.
- **The command does not commit, and does not push.** Everything it does is in your working
  tree and your index until you say otherwise.
- **It reads your identity from the build, not from your manifests.** That means it needs a
  generated project and Xcode, and it means a literal you baked into a generated project
  wins over the manifest that was supposed to produce it — which is exactly why the build is
  the source it trusts.
- **Both platforms must agree.** `app/Identity.xcconfig` holds one bundle id, one display
  name and one copyright. If your two platforms currently resolve different values for any of
  those, the command refuses with both values named rather than picking a winner.
- **A fork that never passed a Team ID** still carries the unsubstituted placeholder in its
  manifests. The command refuses to "move" that, and tells you to put a real Team ID in
  `app/Local.xcconfig` yourself.
- **Syncing template-owned files is still worth doing, even though you no longer have to.**
  The command now points your `bin/`, `ci/`, `fastlane/` and `Makefile` copies at the new
  project and schemes (step 6), so nothing is broken if you stop here. Adopting the
  template's current copies is still what stops the *next* upstream change from needing
  hand-translation — it is an upgrade rather than a repair now.
- **This document is `docs/MIGRATING-FROM-RENAME.md`**, and it is what the command points at
  in its own output and in the comments it writes into your `app/Identity.xcconfig`. If you
  vendored the command, vendor this alongside it.

---

## See also

- [`docs/BOOTSTRAP.md`](BOOTSTRAP.md) — the `.bootstrap.env` field reference, including which
  keys still have a consumer after the identity work.
- [`docs/MIGRATING-TO-TUIST.md`](MIGRATING-TO-TUIST.md) — the other in-place migration for an
  already-renamed fork; the same shape, a different subject.
- [`docs/ADOPTING-EXISTING-APP.md`](ADOPTING-EXISTING-APP.md) — if your fork represents an app
  that is already on the App Store, read this too. It covers the *metadata* half of the same
  risk this document covers the *binary* half of.
- [`AGENTS.md`](../AGENTS.md) — the template-owned boundary, the one xcconfig reader, and why
  identity is edited in `app/Identity.xcconfig` rather than substituted into build files.
- [`CHANGELOG.md`](../CHANGELOG.md) — the breaking-change entry for this migration.
- `docs/PRODUCT-IDENTITY.md` — if your fork keeps one. This is a fork-owned document, not a
  template one, so it may not exist in your tree; it is where a fork records *why* its four
  identity values are what they are.
