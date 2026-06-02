// TODO(T011): Implement authority enforcement.
//             - Owner-as-decider assertion: every primitive call must carry a non-trivial
//               decider identity (FR-020 / Art. XXV / Art. XXVIII)
//             - Risk-tier checks per primitive (contracts/ defines tiers)
//             - Audit trail hook: every call emits an audit record with
//               (decider_identity, correlation_id, primitive, prior_state_hash, after_state_hash)
//             See specs/001-voice-scorebook-core/contracts/ for the per-primitive authority model.
