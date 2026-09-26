---
title: A privacy gate keyed to the device instead of the identity it protects, and PII persisted before the gate that decides it may be kept
date: 2026-08-11
category: logic-errors
module: ios/Sources/Auth + ios/Sources/UI/App
problem_type: logic_error
component: state_machine
symptoms:
  - "One user's COPPA age answer silently pre-answers the gate for the next person to sign in"
  - "A child's under-13 answer permanently blocks every later adult on the same device"
  - "A child's real name and persistent identifier stay in the Keychain after they answer 'under 13'"
  - "The shipped contract claims 'No under-13 PII stored' while the PII is at rest"
root_cause: wrong_scope_key
resolution_type: code_fix
severity: high
tags: [coppa, privacy, consent, keychain, sign-in-with-apple, ios, owner-identity, t081, adr-0016, review-gate, pii]
---

# A privacy gate keyed to the device, and PII written before the gate that decides it may be kept

Two P1 defects found by `/ce-code-review` on PR #172 (T081 owner identity). Both were in code that
looked correct, passed CI, and shipped alongside a contract and ADR asserting the very properties it
violated. They share one root cause worth naming, because it generalizes well past COPPA.

## The two defects

**1. The gate was keyed to the device, not the owner.** `ConsentGate` persisted its one-time answer
under device-global `UserDefaults` keys (`dl.consent.responded`), and `signOut()` never cleared
them. On the shared family iPad this app is explicitly built for:

- an adult answers "13 or older", signs out, a child signs in with their own Apple ID -> the child
  inherits `.allowed` and records freely; the gate is never shown;
- and in reverse, a child's answer permanently blocked every later adult, with `reset()` available
  only under `#if DEBUG`.

**2. PII was persisted before the gate that decides whether it may be kept.** Sign in with Apple
requests `.fullName`, and `establishAppleSession` writes `{ownerId, displayName}` to the Keychain.
That write necessarily happens *before* the age gate can be shown — you cannot ask a user their age
until they have signed in. When the user then answered "under 13", `recordAgeResponse` only wrote a
`UserDefaults` flag. The child's real name plus a persistent identifier stayed at rest until they
chose to tap "Sign out", while the contract and ADR both claimed "No under-13 PII stored."

## Root cause

**A gate's persistence must be keyed to the thing it protects.** The gate protects a *person*
(identified by `ownerId`); keying its answer to the *device* silently makes it a different, weaker
control the moment two people share hardware. The device was the convenient key, not the correct
one, and nothing in the type system or the tests objected.

The second defect is the same mistake in the time dimension: an ordering the flow *forces*
(authenticate -> then ask age) means the protected data exists before the decision does. A gate that
only decides "may they proceed?" and not "may what we already collected be kept?" is a half gate.

## Fix

- `ConsentGate` takes an `ownerId` and namespaces its keys (`dl.consent.responded.<ownerId>`), so
  each owner is asked exactly once and an under-13 block follows that child across sign-ins. Owners
  who answered under the old device-global keys are simply re-asked — the fail-safe direction, since
  a stale answer can never auto-allow.
- `AppState.refreshConsentStatus()` recomputes status whenever the owner changes and enforces a
  storage invariant: **an owner known to be under 13 keeps no persisted session.** The Keychain item
  is deleted on the under-13 answer and re-deleted on any later sign-in by that owner. The in-memory
  session survives only so the blocked screen can explain the refusal.
- `RootView` checks the blocked branch **before** the session branch — otherwise the purge bounces
  the child to a sign-in screen instead of the screen explaining why they cannot record.

```swift
// The invariant, stated in one place.
private func refreshConsentStatus() {
    consentStatus = consentGate?.status ?? .unknown
    if consentStatus == .blockedUnder13 {
        authStore.signOut()          // purge the Keychain identity; keep the in-memory session
    }
}
```

## Detection rule

When reviewing any gate, consent flow, or entitlement check, ask two questions:

1. **What is this keyed to, and is that the thing it protects?** A gate protecting a person keyed to
   a device, a session, an install, or a browser is a bug on any shared instance of that thing.
2. **Does data protected by the gate exist before the gate runs?** If the flow forces collection
   first (auth before age, upload before scan, draft before permission check), the gate must have a
   *retroactive* arm that deletes what was already collected — not just a forward arm that blocks
   the next step.

Grep signals: a `UserDefaults`/`localStorage`/cookie key for a consent/eligibility answer with no
identity component in it; a `record*Response`/`setConsent` function that writes a flag and nothing
else; a claim in a contract or ADR ("no X stored", "we never keep Y") with no deletion call anywhere
in the diff that would make it true.

## Why the tests did not catch it

`ConsentGate`'s unit tests were correct and passed: they exercised one gate instance against one
fresh `UserDefaults` suite, which is precisely the shape that cannot reveal a cross-owner leak. The
enforcement layer above it (`AppState.createGame`'s guard, the routing, the purge) had no tests at
all, because `AppState` hardcoded `AuthStore.shared` and `UserDefaults.standard` and so could not be
constructed hermetically. **A gate tested only in isolation from the identity it gates is tested at
the wrong altitude.** The fix added injectable `consentDefaults` and `authStore` to `AppState`, and
`T081ConsentEnforcementTests` now drives the real seam: two owners on one device, the purge, sign-out
re-ask, and the DEBUG shortcut's blast radius.

## Related

- ADR-0016 (DECISIONS.md) — v1 owner identity; §4 carries both properties now.
- `specs/001-voice-scorebook-core/contracts/owner_identity.md` — contract, corrected in the same pass.
- [Swapping a real stateful core in for a stateless mock](../integration-issues/mock-to-real-stateful-core-swap.md)
  — the same "stub -> real" reconciliation shape: enumerate what the stub made trivial (here: the dev
  stub had no persistence, no revocation, and no consent) and re-verify each against the real thing.
- P1-4 in `../patterns/critical-patterns.md` — owner-as-decider authority; T081 supplies the identity
  that pattern binds to.
