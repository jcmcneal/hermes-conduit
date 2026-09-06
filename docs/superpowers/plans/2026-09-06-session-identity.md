# Session identity implementation plan

**Goal:** Make preserve-current recovery retain conversation ownership through catalog gaps and runtime rebinding.

**Spec:** `docs/superpowers/specs/2026-09-06-session-identity-design.md`

**Architecture:** A small identity value supplies durable recovery targeting and validates resume binding. AppState retains orchestration and existing operation fences; scroll and composer consumers use the accepted binding.

**Constraints:** Preserve unrelated work. Use ios_test fixed-policy driver for Xcode test execution. Do not commit, push, open a PR, or change release metadata.

- [x] Establish isolated Windows and Mac workspaces and run baseline resume suites.
- [x] Add policy, AppState recovery and second-send regression tests before implementation.
- [ ] Verify their expected assertion failures against unchanged production sources.
- [ ] Add explicit resume identity parsing/admission and runtime-rebind tests before that implementation.
- [ ] Add `ConversationIdentity.swift`; capture recovery identity before catalog replacement; eliminate preserve-current fallback/create for an existing identity.
- [ ] Retain durable/runtime binding independently of catalog refresh; connect canonical lookup, alias matching and scroll projection.
- [ ] Rebind composer context only under existing profile/client/epoch/viewport ownership fences.
- [ ] Run focused red/green checks, existing lifecycle/handoff tests, unit/UI suites, CI inventory and planner regression checks.
- [ ] Review the final diff and document actual results, remaining limitations and PR readiness.
