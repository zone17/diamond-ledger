# Contract: owner identity (iOS sign-in → `ownerId`)

The iOS authentication capability that establishes the **authenticated owner** every scoring
primitive binds to. This is the client-side **authentication** layer; the core does
**authorization** only (`core/src/authz.rs` — `assert_authority`/`assert_nontrivial_identity`) and
trusts the `ownerId` this layer supplies. **Risk tier:** 3 (privileged — establishes the identity
all authority and privacy decisions resolve against). **Spec:** FR-020/I5, FR-023, FR-028, FR-029.
**Decision:** ADR-0016 (v1 = on-device Sign in with Apple; email/password deferred to the backend).

## Types

```
AuthSession {
  ownerId:      string        // stable identity; passed to every CoreClient primitive as Actor.id.
                              //   v1 form: "apple:<ASAuthorizationAppleIDCredential.user>"
  displayName:  string        // UI only; NEVER used for an authority decision
  signInMethod: { apple | email | google }   // v1 establishes `.apple` only
}
SignInMethod  = apple | email | google       // email/google reserved (ADR-0016 follow-up a)
AuthError     = notAuthenticated
              | invalidCredentials(string)     // empty/rejected Apple credential
              | persistenceFailed(string)      // Keychain write/clear failed
              | coppaConsentRequired           // reserved: no caller throws it in v1 (see below)
              | methodUnavailable(SignInMethod)
              | cancelled                      // user dismissed the Apple sheet
```

`ownerId` MUST be non-trivial (the core rejects empty / `anonymous` / `unknown`) and MUST originate
from a credential, never from a user-typed field (ADR-0016 threat model).

## Operations

The `ASAuthorizationController` flow itself is owned by the **view** (`SignInView`'s
`SignInWithAppleButton`), not by `AuthStore`: SwiftUI hands back a completed authorization, and the
store's job starts there. So the capability surface is the three synchronous/async calls below —
there is deliberately no `signInWithApple()` on `AuthStore`.

```
establishAppleSession(appleUserID: string, fullName: PersonName?) throws -> AuthSession
                                                   // derives ownerId, persists to the Keychain
restoreSession()  async        -> AuthSession?     // Keychain read + Apple credential-state check
signOut()                                          // clears the Keychain item + in-memory session
```

> COPPA (FR-029): `recordPlay` and game creation MUST NOT proceed until the one-time age gate is
> satisfied **for the signed-in owner**. The gate is a state check, not a thrown error: the client
> exposes `recordingAllowed` (owner signed in AND a 13+ answer) and refuses with a user-facing
> message; `AuthError.coppaConsentRequired` stays reserved for the backend milestone, when an
> agent/CLI caller needs a structured refusal. Under-13 is blocked from recording pending the
> deferred verified-consent flow (ADR-0016 §4).
>
> The answer is persisted **per owner**, not per device — a device-global answer would let one
> owner's response pre-answer the gate for the next person to sign in on a shared device.

## Preconditions

- **Sign-in:** the `com.apple.developer.applesignin` entitlement is present (project.yml) and the
  capability is enabled for the app id (portal — human provisioning step, ADR-0016 Impact).
- **Every scoring primitive:** a live `AuthSession` exists; its `ownerId` is what the core's
  authority assertion validates (FR-020/I5). No session → the UI shows `SignInView`, not a stub.

## Behavior

1. `SignInView` runs `SignInWithAppleButton` (scopes: full name for `displayName`) and hands the
   completed authorization to `establishAppleSession`, which derives
   `ownerId = "apple:" + credential.user`, builds the `AuthSession`, and persists it in the
   Keychain (`…AfterFirstUnlockThisDeviceOnly`). A persistence failure is surfaced on the sign-in
   screen — the only view on screen at that moment.
2. `restoreSession` reads the Keychain item on launch. An `.apple` session whose `ownerId` has lost
   its `apple:` namespace is treated as corrupt: the item is cleared and `nil` returned. Otherwise
   it calls `getCredentialState(forUserID:)` and returns `nil` (signing out) unless the credential
   is `.authorized`.
3. `signOut` deletes the Keychain item and clears the in-memory session.
4. **Under-13 purge (FR-029).** Sign-in necessarily persists `{ownerId, displayName}` before the
   age gate can be shown. The moment the owner answers "under 13", that Keychain item is deleted
   and stays deleted on every later sign-in by that owner — a child's name and persistent
   identifier are never left at rest. The in-memory session survives only so the blocked screen can
   explain the refusal.

## Postconditions

- A successful sign-in yields a session whose `ownerId` is stable across launches and is the exact
  string recorded as the game owner (`created_by`) by `create_game` and matched by every later
  primitive (FR-020). Private-by-default holds: only this `ownerId` can act on its games (FR-023).

## Errors

`notAuthenticated` (no session when one is required) · `cancelled` (user dismissed) ·
`coppaConsentRequired` (age gate unmet) · `methodUnavailable(.email/.google)` (reserved in v1) ·
`invalidCredentials` (Apple authorization failure).

## Security (Art. XXVI/XXVIII/XXIX)

- No password stored (Apple holds the credential); no email stored ("Hide My Email" supported); no
  identity logged. Keychain item is device-scoped. See ADR-0016 threat model.
- **Production safety:** the dev stub (`AppState.devSignIn` → `dev-owner-*`) MUST be `#if DEBUG`;
  a release build cannot mint a stub identity.

## Parity & tests

The agent/CLI surface supplies its own non-trivial capability identity (`dl-score-harness`) — a
named trust boundary (Art. XXIX), not this UI flow. Unit-testable here (device-independent):
`ownerId` derivation (`apple:<user>`), Keychain round-trip (write → restore → match), the COPPA
gate state machine (ask-once; under-13 blocks recording), and that an empty/absent session blocks
every primitive. The full Sign-in-with-Apple sheet is verified on a real device (Apple ID + Xcode
26), like the ASR leg.
