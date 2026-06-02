// TODO(T009): Implement the append-only event log and replay/projection engine.
//             - Immutable event rows: (seq, game_id, event_type, payload, corrects_event_id?)
//             - correct_event appends a COMPENSATING row — never UPDATE or DELETE (FR-013)
//             - finalize_scorecard = replay/fold over the event stream
//             - Projection: derive current GameState by replaying from event 0
//             See data-model.md and research.md D7 for the persistence model.
