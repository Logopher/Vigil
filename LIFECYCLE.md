# LIFECYCLE.md

**Current stage: 0, preparing for 1.**

This document describes the stages Vigil is expected to pass through over its life, what each stage demands of the maintainer, and the transitions between them. It is the whole-arc view. For how the project works today, see `DESIGN.md`.

Update the "current stage" line above when the project moves.

---

## Why stages matter

What works at one stage actively harms the next. Friends extend goodwill strangers do not. Strangers accept "best-effort" community users do not. Premature formalism wastes effort at Stage 1 absent formalism betrays users at Stage 3. The practical goal is to match investment to the stage you can observe, not the one you hope for.

A security-first tool sits on a stricter track than a generic CLI. Trust compounds, and a shortcut taken at Stage 1 is hard to undo at Stage 4. Prefer honest limitations over quietly incomplete promises at every stage.

---

## Stage definitions

### Stage 0 -- Personal

One user. No interface, no docs beyond commit messages. The repo is scratchpad and backup.

- **Demands:** nothing beyond "it works on my machine."
- **Allows:** breaking changes at any time, no versioning, no tests.
- **Anti-goal:** building infrastructure for users who do not exist.

### Stage 1 -- Shareable dotfiles

2-20 trusted friends. Support is DMs; HEAD is "the release."

- **Demands:**
  - README explaining what it is, who it is for, and what it will not do.
  - Idempotent `install.sh` and a real `uninstall.sh`.
  - License file.
  - No secrets committed; clear boundary between tool config and user credentials.
  - Basic smoke test that can run in an ephemeral `$HOME`.
- **Allows:** breaking changes announced in DM; platform scope limited to the maintainer's own (Linux/WSL).
- **Anti-goal:** Stage 2 infrastructure (release pipeline, stable API, issue templates) before a stranger has ever tried to use the project.

### Stage 2 -- Findable OSS

20-500 strangers discover the project via search, social posts, or word of mouth. They cannot reach the maintainer directly and will either file issues or silently fail.

- **Demands:**
  - README that stands alone for a reader with zero context.
  - Explicit supported-platforms statement. Silence is an implicit promise.
  - Tagged releases and a CHANGELOG, so "which version broke it" is answerable.
  - Issue template, even minimal.
  - Explicit support stance: "best-effort," "issues read weekly," "no support." Absence of a stance becomes an implicit SLA.
- **Allows:** no contribution workflow yet -- "PRs not accepted, feedback via issues" is a legitimate posture.
- **Anti-goal:** accepting a PR without having decided the CLA/DCO question first.

### Stage 3 -- Maintained community OSS

500-5000 users, regular PRs and contributor questions. Being a maintainer is now a part-time job whether planned or not.

- **Demands:**
  - Contribution guide, DCO or CLA, code of conduct.
  - Semver discipline. Breaking changes only in major versions.
  - CI running across claimed platforms. "Chris tries it" is no longer sufficient.
  - Security disclosure policy and a private reporting route.
  - Triage cadence documented.
- **Allows:** opinionated direction; "no" is still the default answer to feature requests.
- **Anti-goal:** drifting into Stage 3 without a sustainability plan. Many projects die of success here -- all the work, none of the revenue or recognition.

### Stage 4 -- Supported OSS / pre-commercial

Still free and open, but with an explicit sustainability model: hosted version, paid support, sponsorship, employer-funded, or deliberate subsidy.

- **Demands:**
  - A revenue or sustainability model, even modest.
  - Signed releases, SBOM, a stance on reproducibility -- security-adjacent projects are held to a higher bar here.
  - Documentation treated as a first-class product.
  - Governance, even if informal ("Chris has final say; here are the three trusted reviewers").
- **Allows:** paid services adjacent to free core; commercial support contracts.
- **Anti-goal:** shipping enterprise features before the hobby-scale user experience is solid.

### Stage 5 -- Commercial product

OSS core often remains; value moves to hosted service, enterprise features (SSO, audit logs, compliance), integrations, and support contracts.

- **Demands:** incorporation, terms of service, privacy policy, billing infrastructure, customer success, pricing experiments.
- **Allows:** paid tiers, bespoke contracts, closed-source components alongside open core.
- **Anti-goal:** treating Stage 5 as a promotion. It is a different job.

---

## Transitions

Transitions are listed with their cost and their most common failure mode.

### 0 -> 1: the README gate

- **Cost:** low. One good README, an `install.sh`, an `uninstall.sh`, a license.
- **Cannot be skipped.** A weak README sinks an otherwise solid project the moment it touches a second user.
- **Failure mode:** sharing the repo with friends before it is installable in one command.

### 1 -> 2: friends to strangers

- **Cost:** medium. Docs rewrite for zero-context readers, platform statement, release discipline, support posture.
- **Failure mode:** assuming goodwill scales. It does not. Confusing behavior that friends forgive becomes bug reports from strangers.

### 2 -> 3: OSS to community OSS

- **Cost:** high. This transition is a lifestyle decision, not a technical one. Accepting PRs means becoming a maintainer.
- **Not every project should graduate.** "Archive mode: no new features, PRs welcome, maintained for correctness" is a legitimate terminus at Stage 2.
- **Failure mode:** sliding into Stage 3 without consciously accepting the maintenance burden, then burning out.

### 3 -> 4: unpaid to sustainable

- **Cost:** high. Requires a revenue or sustainability decision and retroactive contributor-rights work if CLA/DCO was skipped earlier.
- **Failure mode:** staying in Stage 3 indefinitely while hoping sustainability will appear on its own.

### 4 -> 5: OSS to commercial

- **Cost:** very high. Legal entity, terms, billing, go-to-market. A different job.
- **Failure mode:** optimizing the OSS core for the commercial product before commercial validation exists.

---

## Decisions that cast shadows backward

A few choices are cheap now and expensive or impossible to retrofit. Decide them before the stage that forces them.

| Decision | Decide before | Why |
|---|---|---|
| License | first outside user | Relicensing requires contributor consent once PRs are accepted. |
| CLA or DCO | first outside contributor | Retrofitting contributor rights often means rewriting history or contacting every contributor. |
| Contribution posture | first PR | "PRs not accepted" is legitimate and buys time; reversing "PRs accepted" is painful. |
| Support stance | first issue filed by a stranger | Absence becomes an implicit promise. |
| Public telemetry policy | first release | Adding telemetry later damages trust; removing it is easy. |
| Platform scope claim | first README that strangers read | Claiming "Linux" brings Alpine, NixOS, and musl reports. Claim "Linux/WSL2, Ubuntu-family tested" instead. |

Default picks for this project pending explicit revisitation:

- **License:** to be chosen before any stranger uses the project. MIT or Apache-2.0 for maximum adoption and optional later commercialization; AGPL if a hard commercial moat is desired.
- **CLA/DCO:** to be decided before the first outside PR. DCO is the lightweight option; CLA keeps more future flexibility.
- **Contribution posture at Stage 1:** "PRs not accepted, feedback via issues." Revisit at Stage 2.
- **Telemetry:** none, ever, without explicit opt-in and documented payload.

---

## Anti-stages

Two shapes the project should avoid:

- **Aspirational Stage N.** Building infrastructure for users who do not exist. Semver at Stage 1, governance at Stage 2, dashboards at Stage 3 when no one has asked. Every such artifact is maintenance debt with no user.
- **Ghost Stage 3.** Accepting contributions, fielding issues, making promises, without having accepted the maintenance burden. This is the burnout stage. If Stage 3 obligations appear but Stage 3 commitment is absent, retreat to Stage 2 with an explicit archive-mode notice.

---

## Using this document

- When the current stage changes, update the pointer at the top.
- When a new demand or anti-goal is recognized at any stage, add it here rather than scattering the insight across commit messages and issues.
- When a transition is attempted, review its "failure mode" line first. If the failure mode is already visible, pause and fix it before continuing.

---

*LIFECYCLE.md -- Vigil -- Rev 1*
