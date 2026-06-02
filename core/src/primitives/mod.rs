// TODO(T004): Implement the four atomic primitives:
//             record_play · advance_runner · correct_event · finalize_scorecard
//             These are the only mutation entry-points (Art. III). Each must:
//               - validate the caller's authority (authz module)
//               - produce a structured event written to the eventlog
//               - return a typed Result (never panic on invalid input)
//             See contracts/ for the typed I/O and error model per primitive.
