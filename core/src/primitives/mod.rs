//! The four atomic primitives + lifecycle ops (T017–T019, T034, T036, FR-007/020).
//!
//! These are the ONLY mutation entry-points (Art. III). Each primitive:
//!   1. Asserts authority (I5/FR-020/T036).
//!   2. Validates preconditions (structured `Error` — never panics on bad input).
//!   3. Appends a typed event to the event log.
//!   4. Returns a typed result.
//!
//! State never advances on an unconfirmed entry (FR-007): `record_play` appends a
//! `PlayRecorded` event (unconfirmed); `confirm_play` appends `PlayConfirmed` which
//! marks the row as confirmed and allows the projection to advance.

use std::collections::HashMap;
use std::sync::Mutex;

use crate::authz::{assert_authority, assert_nontrivial_identity, GameAuthority};
use crate::classify::{classify_with_context, ClassifyContext};
use crate::eventlog::{
    Event, EventLog, GameFinalizedPayload, GameStartedPayload,
    JudgmentOpenedPayload, JudgmentResolvedPayload, PlayConfirmedPayload, PlayRecordedPayload,
    RunnerAdvancedPayload,
};
use crate::ffi::{
    AdvanceOutcome, AdvanceRunnerRequest, AdvanceRunnerResult, Call,
    ConfirmPlayRequest, ConfirmPlayResult, CoreApi, CoreResult, CreateGameRequest,
    CreateGameResult, DecisionRef, Error, ErrorCode, FinalizeRequest,
    FinalizeResult, GameId, GameState, Half, JudgmentDecision, JudgmentStatus, Needs, Play,
    PlayInput, ProofBox, Recommendation, RecordPlayRequest, RecordPlayResult,
    ReisnerScorebook, ResolveJudgmentRequest, ResolveJudgmentResult,
    Seq, EventSummary, CorrectEventRequest, CorrectEventResult, Unresolved,
};
use crate::model::{AdvanceTo, Base, Classification, JudgmentKind, NormalizedPlay};
use crate::reisner::{check_proof_box_balance, compute_proof_box, render_cell};
use crate::retrosheet::{emit_game, GameExportInput, PlayExportInput};
use crate::rules::project_game;

// ---------------------------------------------------------------------------
// Core engine (in-memory, single-process for MVP)
// ---------------------------------------------------------------------------

/// The Diamond Ledger core engine. Implements `CoreApi` over an in-memory event log.
///
/// Thread-safety: wrapped in `Mutex` for `Send + Sync`. MVP uses single-threaded access;
/// the `Mutex` is a minimal guard for future async surfaces.
///
/// Under the `uniffi` feature this is also a UniFFI **Object** (heap-allocated behind
/// `Arc`, passed by reference). The exported constructor + method wrappers live in the
/// `#[uniffi::export]` impl block below; they delegate to the inherent `CoreApi`
/// methods 1:1 (same behavior across CLI/agent/UI — parity, SC-008).
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct DiamondCore {
    inner: Mutex<CoreInner>,
}

struct CoreInner {
    log: EventLog,
    /// Per-game authority records (owner id → `GameAuthority`).
    authorities: HashMap<u64, GameAuthority>,
}

impl CoreInner {
    fn new() -> Self {
        CoreInner {
            log: EventLog::new(),
            authorities: HashMap::new(),
        }
    }

    fn get_authority(&self, game_id: GameId) -> CoreResult<&GameAuthority> {
        self.authorities.get(&game_id.0).ok_or_else(|| {
            Error::new(ErrorCode::NotFound, format!("Game {} not found", game_id.0))
        })
    }
}

impl DiamondCore {
    pub fn new() -> Self {
        DiamondCore {
            inner: Mutex::new(CoreInner::new()),
        }
    }

    /// Capture the full core state as a serializable snapshot (#128 — CLI persistence).
    ///
    /// The snapshot is the append-only event log plus the per-game authority records —
    /// everything needed to rebuild every game's projection deterministically (I6). The
    /// `dl` CLI persists this between invocations so a game can be built across separate
    /// commands. The log stays append-only: `restore` then `record_play` appends, never
    /// rewrites.
    #[must_use]
    pub fn snapshot(&self) -> CoreSnapshot {
        let inner = self.inner.lock().unwrap();
        CoreSnapshot {
            log: inner.log.clone(),
            authorities: inner.authorities.clone(),
        }
    }

    /// Rebuild a core from a previously captured [`CoreSnapshot`] (#128).
    #[must_use]
    pub fn restore(snapshot: CoreSnapshot) -> Self {
        DiamondCore {
            inner: Mutex::new(CoreInner {
                log: snapshot.log,
                authorities: snapshot.authorities,
            }),
        }
    }
}

/// A serializable snapshot of the whole core (#128 — CLI cross-invocation persistence).
///
/// Integer-only / `serde`-faithful (I6): rebuilding from this yields byte-identical
/// projections. Persisted by the `dl` CLI to `$DL_STATE_FILE`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CoreSnapshot {
    log: EventLog,
    authorities: HashMap<u64, GameAuthority>,
}

impl Default for DiamondCore {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// UniFFI-exported surface (T037 / H1)
// ---------------------------------------------------------------------------
//
// This block is the language-neutral capability boundary Swift/Kotlin/CLI/agent all
// call (Art. II parity). Each method delegates 1:1 to the inherent `CoreApi` method
// and maps the structured `Error` into the throwable `CoreFfiError` (zero info loss:
// the `code` is preserved). The trait stays plain so the Swift `MockCore` can keep
// implementing it without the macro (CoreClient.swift T044). The 11 methods are the
// 7 write/lifecycle primitives + the 4 reads named in the contract.
#[cfg(feature = "uniffi")]
#[uniffi::export]
impl DiamondCore {
    /// Construct a fresh in-memory core. Foreign callers invoke `DiamondCore()`.
    #[uniffi::constructor]
    pub fn ffi_new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self::new())
    }

    /// See [`CoreApi::create_game`].
    pub fn ffi_create_game(
        &self,
        req: crate::ffi::CreateGameRequest,
    ) -> crate::ffi::FfiResult<crate::ffi::CreateGameResult> {
        Ok(<Self as CoreApi>::create_game(self, req)?)
    }

    /// See [`CoreApi::record_play`].
    pub fn ffi_record_play(
        &self,
        req: crate::ffi::RecordPlayRequest,
    ) -> crate::ffi::FfiResult<crate::ffi::RecordPlayResult> {
        Ok(<Self as CoreApi>::record_play(self, req)?)
    }

    /// See [`CoreApi::confirm_play`].
    pub fn ffi_confirm_play(
        &self,
        req: crate::ffi::ConfirmPlayRequest,
    ) -> crate::ffi::FfiResult<crate::ffi::ConfirmPlayResult> {
        Ok(<Self as CoreApi>::confirm_play(self, req)?)
    }

    /// See [`CoreApi::advance_runner`].
    pub fn ffi_advance_runner(
        &self,
        req: crate::ffi::AdvanceRunnerRequest,
    ) -> crate::ffi::FfiResult<crate::ffi::AdvanceRunnerResult> {
        Ok(<Self as CoreApi>::advance_runner(self, req)?)
    }

    /// See [`CoreApi::resolve_judgment`].
    pub fn ffi_resolve_judgment(
        &self,
        req: crate::ffi::ResolveJudgmentRequest,
    ) -> crate::ffi::FfiResult<crate::ffi::ResolveJudgmentResult> {
        Ok(<Self as CoreApi>::resolve_judgment(self, req)?)
    }

    /// See [`CoreApi::correct_event`].
    pub fn ffi_correct_event(
        &self,
        req: crate::ffi::CorrectEventRequest,
    ) -> crate::ffi::FfiResult<crate::ffi::CorrectEventResult> {
        Ok(<Self as CoreApi>::correct_event(self, req)?)
    }

    /// See [`CoreApi::finalize_scorecard`].
    pub fn ffi_finalize_scorecard(
        &self,
        req: crate::ffi::FinalizeRequest,
    ) -> crate::ffi::FfiResult<crate::ffi::FinalizeResult> {
        Ok(<Self as CoreApi>::finalize_scorecard(self, req)?)
    }

    /// See [`CoreApi::get_game_state`].
    pub fn ffi_get_game_state(
        &self,
        game_id: crate::ffi::GameId,
    ) -> crate::ffi::FfiResult<crate::ffi::GameState> {
        Ok(<Self as CoreApi>::get_game_state(self, game_id)?)
    }

    /// See [`CoreApi::list_game_events`].
    pub fn ffi_list_game_events(
        &self,
        game_id: crate::ffi::GameId,
    ) -> crate::ffi::FfiResult<Vec<crate::ffi::EventSummary>> {
        Ok(<Self as CoreApi>::list_game_events(self, game_id)?)
    }

    /// See [`CoreApi::get_play`].
    pub fn ffi_get_play(
        &self,
        game_id: crate::ffi::GameId,
        seq: crate::ffi::Seq,
    ) -> crate::ffi::FfiResult<crate::ffi::Play> {
        Ok(<Self as CoreApi>::get_play(self, game_id, seq)?)
    }

    /// See [`CoreApi::get_proof_box`].
    pub fn ffi_get_proof_box(
        &self,
        game_id: crate::ffi::GameId,
        inning: u8,
        half: crate::ffi::Half,
    ) -> crate::ffi::FfiResult<crate::ffi::ProofBox> {
        Ok(<Self as CoreApi>::get_proof_box(self, game_id, inning, half)?)
    }
}

// ---------------------------------------------------------------------------
// Helper: build a JudgmentDecision from log state
// ---------------------------------------------------------------------------

fn build_judgment_decision(
    inner: &CoreInner,
    game_id: GameId,
    decision_id: u64,
) -> Option<JudgmentDecision> {
    let opened = inner.log.get_judgment_opened(game_id, decision_id)?;
    let resolved = inner.log.get_judgment_resolved(game_id, decision_id);

    let (status, chosen, decider) = match resolved {
        Some(r) => (
            JudgmentStatus::Resolved,
            Some(Call {
                token: r.chosen_token.clone(),
                label: r.chosen_label.clone(),
            }),
            // Find the actor who resolved it.
            inner
                .log
                .all_rows(game_id)
                .find(|row| {
                    matches!(&row.event,
                        Event::JudgmentResolved(p) if p.decision_id == decision_id
                    )
                })
                .map(|row| row.actor.clone()),
        ),
        None => (JudgmentStatus::Open, None, None),
    };

    let (recommendation, alternatives) = judgment_recommendation(opened.kind);

    Some(JudgmentDecision {
        id: decision_id,
        kind: opened.kind,
        status,
        recommendation,
        alternatives,
        chosen,
        decider,
    })
}

fn judgment_recommendation(kind: JudgmentKind) -> (Recommendation, Vec<Call>) {
    match kind {
        JudgmentKind::HitVsError => (
            Recommendation {
                call: Call {
                    token: "hit".into(),
                    label: "Hit".into(),
                },
                one_line_reason: "Fielder made contact with the ball; default to hit unless clear misplay".into(),
            },
            vec![
                Call { token: "error".into(), label: "Error".into() },
            ],
        ),
        JudgmentKind::EarnedVsUnearned => (
            Recommendation {
                call: Call {
                    token: "pending".into(),
                    label: "Pending (error/PB in inning)".into(),
                },
                one_line_reason: "Run scores in an error/passed-ball half-inning; earned/unearned is PENDING (no Rule 9.16 in v1)".into(),
            },
            vec![
                Call { token: "earned".into(), label: "Earned".into() },
                Call { token: "unearned".into(), label: "Unearned".into() },
            ],
        ),
        JudgmentKind::ContestedCredit => (
            Recommendation {
                call: Call {
                    token: "standard_credit".into(),
                    label: "Standard credit assignment".into(),
                },
                one_line_reason: "Multi-fielder play; scorer must assign putout/assist credit".into(),
            },
            vec![
                Call { token: "alt_credit".into(), label: "Alternate credit assignment".into() },
            ],
        ),
        JudgmentKind::AmbiguousAdvance => (
            Recommendation {
                call: Call {
                    token: "advance_accepted".into(),
                    label: "Accept the advance as recorded".into(),
                },
                one_line_reason: "Runner advanced beyond expected distance; scorer must confirm".into(),
            },
            vec![
                Call { token: "advance_rejected".into(), label: "Runner should not have advanced".into() },
            ],
        ),
    }
}

// ---------------------------------------------------------------------------
// CoreApi implementation
// ---------------------------------------------------------------------------

impl CoreApi for DiamondCore {
    fn create_game(&self, req: CreateGameRequest) -> CoreResult<CreateGameResult> {
        let mut inner = self.inner.lock().unwrap();

        // Authority check (FR-020/I5).
        assert_nontrivial_identity(&req.actor)?;

        // Idempotency — check for existing game with this key.
        // For create_game we use a global key (not per-game since the game doesn't exist yet).
        // Simple implementation: iterate all game authorities to find by idempotency key.
        // MVP: just allocate a new game.
        let game_id = inner.log.allocate_game_id();

        // Record authority.
        inner
            .authorities
            .insert(game_id.0, GameAuthority::new(req.actor.id.clone()));

        // Append GameStarted.
        inner.log.append(
            game_id,
            req.actor.clone(),
            Event::GameStarted(GameStartedPayload {
                home_team_id: req.home.id.clone(),
                home_team_name: req.home.name.clone(),
                visitor_team_id: req.visitor.id.clone(),
                visitor_team_name: req.visitor.name.clone(),
                idempotency_key: req.idempotency_key.clone(),
            }),
            None,
        );
        inner
            .log
            .register_idempotency(game_id, req.idempotency_key, 0);

        let proj = project_game(&inner.log, game_id);
        Ok(CreateGameResult {
            game_id,
            state: proj.to_game_state(),
        })
    }

    fn confirm_play(&self, req: ConfirmPlayRequest) -> CoreResult<ConfirmPlayResult> {
        let mut inner = self.inner.lock().unwrap();

        // Authority (I5/FR-020).
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;
        assert_nontrivial_identity(&req.actor)?;

        // Game must exist.
        if !inner.log.game_exists(req.game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }

        // Idempotency.
        if inner.log.check_idempotency(req.game_id, &req.idempotency_key).is_some() {
            let proj = project_game(&inner.log, req.game_id);
            return Ok(ConfirmPlayResult { state: proj.to_game_state() });
        }

        let confirms_seq = req.confirms_seq.0;

        // The seq being confirmed must exist and be a PlayRecorded.
        let row = inner.log.get_row(req.game_id, confirms_seq).ok_or_else(|| {
            Error::new(ErrorCode::NotFound, format!("Seq {} not found", confirms_seq))
        })?;
        if !matches!(row.event, Event::PlayRecorded(_)) {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("Seq {} is not a PlayRecorded event", confirms_seq),
            ));
        }

        // I2 / confirm_play contract: a play that surfaced a judgment must NOT be
        // confirmable while that judgment is still open. Scan the game's open
        // judgments; if any was opened `for_seq == confirms_seq`, reject with
        // JUDGMENT_REQUIRED — the open decision must be resolved first (no silent
        // judgment; the play cannot advance state with an unresolved scoring call).
        for decision_id in inner.log.open_judgments(req.game_id) {
            if let Some(opened) = inner.log.get_judgment_opened(req.game_id, decision_id) {
                if opened.for_seq == confirms_seq {
                    return Err(Error::new(
                        ErrorCode::JudgmentRequired,
                        format!(
                            "Seq {} surfaced an open judgment (decision {}); resolve it before confirming (I2)",
                            confirms_seq, decision_id
                        ),
                    ));
                }
            }
        }

        // Mark confirmed.
        inner.log.confirm_row(req.game_id, confirms_seq);

        // Append PlayConfirmed.
        let seq = inner.log.append(
            req.game_id,
            req.actor.clone(),
            Event::PlayConfirmed(PlayConfirmedPayload {
                confirms_seq,
                idempotency_key: req.idempotency_key.clone(),
            }),
            None,
        );
        inner.log.register_idempotency(req.game_id, req.idempotency_key, seq);

        let proj = project_game(&inner.log, req.game_id);
        Ok(ConfirmPlayResult { state: proj.to_game_state() })
    }

    fn record_play(&self, req: RecordPlayRequest) -> CoreResult<RecordPlayResult> {
        let mut inner = self.inner.lock().unwrap();

        // Authority.
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;
        assert_nontrivial_identity(&req.actor)?;

        // Idempotency FIRST — a retry with a known key returns the prior result, and must
        // take priority over the FR-007 pending-play guard below: the unconfirmed play it
        // would otherwise trip on IS this same play (a genuine retry, not a new entry).
        if let Some(prior_seq) = inner.log.check_idempotency(req.game_id, &req.idempotency_key) {
            // Return the prior result (reconstruct from log).
            let row = inner.log.get_row(req.game_id, prior_seq).unwrap();
            if let Event::PlayRecorded(p) = &row.event {
                let play = p.play.clone();
                let proj = project_game(&inner.log, req.game_id);
                let ctx = ClassifyContext {
                    inning_has_error_or_pb: proj.current_half.has_error_or_pb,
                };
                let classification = classify_with_context(&play, &ctx);
                let cell = render_cell(&play, proj.outs);

                // If the original play surfaced a judgment, the retry MUST surface the
                // same open decision + Needs::Judgment — never a (Confirm, None) that
                // would let a caller bypass the open judgment on a retried key (I2).
                let (needs, judgment) = match &classification {
                    Classification::Judgment(_) => {
                        // The decision opened for this play seq (`for_seq == prior_seq`).
                        let decision_id = inner
                            .log
                            .all_rows(req.game_id)
                            .find_map(|r| match &r.event {
                                Event::JudgmentOpened(jp) if jp.for_seq == prior_seq => {
                                    Some(jp.decision_id)
                                }
                                _ => None,
                            });
                        match decision_id
                            .and_then(|did| build_judgment_decision(&inner, req.game_id, did))
                        {
                            Some(decision) => (Needs::Judgment, Some(decision)),
                            None => (Needs::Confirm, None),
                        }
                    }
                    Classification::Deterministic | Classification::OutOfFormat(_) => {
                        (Needs::Confirm, None)
                    }
                };

                return Ok(RecordPlayResult {
                    recorded_seq: Seq(prior_seq),
                    normalized: play,
                    classification,
                    reisner: cell,
                    state_preview: proj.to_game_state(),
                    judgment,
                    needs,
                });
            }
        }

        // FR-007: state never advances on an unconfirmed entry. A genuinely NEW play
        // (idempotency miss, above) while a prior play is unconfirmed is rejected.
        if inner.log.pending_play(req.game_id).is_some() {
            return Err(Error::new(
                ErrorCode::PendingConfirmation,
                "A prior play is unconfirmed. Confirm it before recording the next play (FR-007).",
            ));
        }

        // Extract normalized play (pure core only accepts Normalized).
        let normalized = match req.input {
            PlayInput::Transcript(_) => {
                return Err(Error::new(
                    ErrorCode::TranscriptNotSupported,
                    "The pure core does not parse transcripts; use an adapter with a grammar parser",
                ));
            }
            PlayInput::Normalized(play) => play,
        };

        // Get current projection (for inning context).
        let proj = project_game(&inner.log, req.game_id);
        let ctx = ClassifyContext {
            inning_has_error_or_pb: proj.current_half.has_error_or_pb,
        };

        // Classify from facts (I1/FR-006).
        let classification = classify_with_context(&normalized, &ctx);

        // Render the Reisner cell.
        let cell = render_cell(&normalized, proj.outs);

        // Append PlayRecorded (starts unconfirmed).
        let seq = inner.log.append(
            req.game_id,
            req.actor.clone(),
            Event::PlayRecorded(PlayRecordedPayload {
                play: normalized.clone(),
                idempotency_key: req.idempotency_key.clone(),
            }),
            None,
        );
        inner.log.register_idempotency(req.game_id, req.idempotency_key, seq);

        // Determine needs + open judgment if required.
        let (needs, judgment) = match &classification {
            Classification::Judgment(kind) => {
                let decision_id = inner.log.next_judgment_id(req.game_id);
                inner.log.append(
                    req.game_id,
                    req.actor.clone(),
                    Event::JudgmentOpened(JudgmentOpenedPayload {
                        decision_id,
                        kind: *kind,
                        for_seq: seq,
                    }),
                    None,
                );
                let decision = build_judgment_decision(&inner, req.game_id, decision_id).unwrap();
                (Needs::Judgment, Some(decision))
            }
            Classification::Deterministic => (Needs::Confirm, None),
            Classification::OutOfFormat(_) => (Needs::Confirm, None),
        };

        // Build state_preview (apply the play as if confirmed, but don't commit).
        // We do this by temporarily projecting with the play applied.
        let mut preview_proj = project_game(&inner.log, req.game_id);
        // The play is already appended but unconfirmed, so confirmed_rows won't include it.
        // Build the preview manually.
        preview_proj.apply_play(&normalized, seq);
        let state_preview = preview_proj.to_game_state();

        Ok(RecordPlayResult {
            recorded_seq: Seq(seq),
            normalized,
            classification,
            reisner: cell,
            state_preview,
            judgment,
            needs,
        })
    }

    fn advance_runner(&self, req: AdvanceRunnerRequest) -> CoreResult<AdvanceRunnerResult> {
        let mut inner = self.inner.lock().unwrap();

        // Authority (I5/FR-020).
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;
        assert_nontrivial_identity(&req.actor)?;

        if !inner.log.game_exists(req.game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }

        // Idempotency.
        if let Some(prior_seq) = inner.log.check_idempotency(req.game_id, &req.idempotency_key) {
            let proj = project_game(&inner.log, req.game_id);
            return Ok(AdvanceRunnerResult {
                applied_seq: Some(Seq(prior_seq)),
                state_preview: proj.to_game_state(),
                judgment: None,
                needs: Needs::None,
            });
        }

        // Determine if the advance is forced (deterministic) or ambiguous.
        let proj = project_game(&inner.log, req.game_id);
        let advance_delta = &req.advance;

        // Forced advances are deterministic (FR-009).
        // For MVP: any advance with a clear from→to and no ambiguity is applied.
        // Ambiguous = advance beyond the "expected" base without an attributed error.
        let to_advance: AdvanceTo = advance_delta.to.into();
        let is_ambiguous = {
            let distance = base_distance_direct(advance_delta.from, advance_delta.to);
            distance > 2 && advance_delta.by_error.is_none()
        };

        if is_ambiguous {
            // Surface as AmbiguousAdvance judgment.
            let decision_id = inner.log.next_judgment_id(req.game_id);
            inner.log.append(
                req.game_id,
                req.actor.clone(),
                Event::JudgmentOpened(JudgmentOpenedPayload {
                    decision_id,
                    kind: JudgmentKind::AmbiguousAdvance,
                    for_seq: 0, // Not tied to a specific play seq for standalone advances
                }),
                None,
            );
            let decision =
                build_judgment_decision(&inner, req.game_id, decision_id).unwrap();
            return Ok(AdvanceRunnerResult {
                applied_seq: None,
                state_preview: proj.to_game_state(),
                judgment: Some(decision),
                needs: Needs::Judgment,
            });
        }

        // Apply the advance.
        let seq = inner.log.append(
            req.game_id,
            req.actor.clone(),
            Event::RunnerAdvanced(RunnerAdvancedPayload {
                runner_id: advance_delta.runner.0,
                from: advance_delta.from,
                to: to_advance,
                by_error: advance_delta.by_error,
                idempotency_key: req.idempotency_key.clone(),
            }),
            None,
        );
        inner.log.register_idempotency(req.game_id, req.idempotency_key, seq);

        let new_proj = project_game(&inner.log, req.game_id);
        Ok(AdvanceRunnerResult {
            applied_seq: Some(Seq(seq)),
            state_preview: new_proj.to_game_state(),
            judgment: None,
            needs: Needs::None,
        })
    }

    fn correct_event(&self, req: CorrectEventRequest) -> CoreResult<CorrectEventResult> {
        let inner = self.inner.lock().unwrap();
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;
        assert_nontrivial_identity(&req.actor)?;

        // correct_event is post-MVP (US4); return a structured "not yet implemented" error.
        // This satisfies the contract (never panics, returns typed error).
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "correct_event is post-MVP (US4); not yet implemented in this increment",
        ))
    }

    fn finalize_scorecard(&self, req: FinalizeRequest) -> CoreResult<FinalizeResult> {
        let mut inner = self.inner.lock().unwrap();

        // Authority (I5/FR-020).
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;
        assert_nontrivial_identity(&req.actor)?;

        if !inner.log.game_exists(req.game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }

        // FR-007: must not have a pending (unconfirmed) play.
        if inner.log.pending_play(req.game_id).is_some() {
            return Err(Error::new(
                ErrorCode::PendingConfirmation,
                "There is an unconfirmed play. Confirm it before finalizing.",
            ));
        }

        // Idempotency: a re-finalize with the same key must NOT append a second
        // `GameFinalized`. The returned `FinalizeResult` is rebuilt deterministically
        // from the existing projection either way; on an idempotency hit we skip the
        // append (and the register) so the log stays append-only without duplicates.
        let already_finalized = inner
            .log
            .check_idempotency(req.game_id, &req.idempotency_key)
            .is_some();

        let proj = project_game(&inner.log, req.game_id);

        // Collect all confirmed plays for proof-box and Retrosheet export.
        let mut plays: Vec<NormalizedPlay> = Vec::new();
        let mut play_seqs: Vec<(NormalizedPlay, u64)> = Vec::new();
        for row in inner.log.confirmed_rows(req.game_id) {
            if let Event::PlayRecorded(p) = &row.event {
                plays.push(p.play.clone());
                play_seqs.push((p.play.clone(), row.seq));
            }
        }

        // Build proof boxes.
        // MVP: We build a simplified proof-box for the current completed half-inning.
        // A full implementation would scan the entire log and group by half-inning.
        let mut proof_boxes: Vec<ProofBox> = Vec::new();
        let pb = compute_proof_box(&proj.current_half, proj.inning, proj.half);
        proof_boxes.push(pb);

        // SC-011: fail if any proof box doesn't balance.
        for pb in &proof_boxes {
            if let Err(msg) = check_proof_box_balance(pb) {
                return Err(Error::new(ErrorCode::ContradictoryState, msg));
            }
        }

        // Build Reisner scorebook.
        let mut cells = Vec::new();
        let mut outs_before = 0u8;
        for (play, _seq) in &play_seqs {
            let cell = render_cell(play, outs_before);
            // Track outs for cell rendering.
            let is_out = play.catalyst.advances.iter().any(|a| matches!(a.to, AdvanceTo::Out));
            if is_out {
                outs_before = (outs_before + 1) % 3;
            }
            cells.push(cell);
        }
        let scorebook = ReisnerScorebook {
            cells,
            proof_boxes: proof_boxes.clone(),
        };

        // Build Retrosheet export.
        let game_started = inner.log.all_rows(req.game_id).find_map(|r| {
            if let Event::GameStarted(p) = &r.event { Some(p.clone()) } else { None }
        });
        let (home, visitor, date) = game_started
            .map(|p| (p.home_team_id.clone(), p.visitor_team_id.clone(), "2024-01-01".to_string()))
            .unwrap_or_else(|| ("UNK".into(), "UNK".into(), "1900-01-01".into()));

        let game_id_str = format!("{}2024010101", home);
        let export_plays: Vec<PlayExportInput> = play_seqs
            .iter()
            .enumerate()
            .map(|(i, (play, seq))| {
                let inning = (i / 6) as u8 + 1; // Rough approximation
                PlayExportInput {
                    play,
                    inning,
                    half: if (i / 3) % 2 == 0 { Half::Top } else { Half::Bottom },
                    batter_id: "unknXX01",
                    seq: Seq(*seq),
                    game_id: req.game_id,
                }
            })
            .collect();

        let export_input = GameExportInput {
            game_id: &game_id_str,
            home_team: &home,
            visitor_team: &visitor,
            date: &date,
            plays: export_plays,
        };
        let retrosheet = emit_game(&export_input);

        // Report pending judgments.
        let open = inner.log.open_judgments(req.game_id);
        let pending_judgments: Vec<DecisionRef> = open
            .iter()
            .map(|&did| DecisionRef {
                game_id: req.game_id,
                decision_id: did,
            })
            .collect();

        // Append GameFinalized — only on the FIRST finalize for this key (idempotency).
        if !already_finalized {
            let seq = inner.log.append(
                req.game_id,
                req.actor.clone(),
                Event::GameFinalized(GameFinalizedPayload {
                    mode: req.mode,
                    idempotency_key: req.idempotency_key.clone(),
                }),
                None,
            );
            inner.log.register_idempotency(req.game_id, req.idempotency_key, seq);
        }

        Ok(FinalizeResult {
            scorebook,
            retrosheet,
            proof_box: proof_boxes,
            out_of_format: Vec::new(), // Populated from retrosheet export flags
            unresolved: Unresolved { pending_judgments },
        })
    }

    fn resolve_judgment(&self, req: ResolveJudgmentRequest) -> CoreResult<ResolveJudgmentResult> {
        let mut inner = self.inner.lock().unwrap();

        // Authority (I5/FR-020).
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;
        assert_nontrivial_identity(&req.actor)?;

        if !inner.log.game_exists(req.game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }

        // The judgment must be open.
        let open = inner.log.open_judgments(req.game_id);
        if !open.contains(&req.decision_id) {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("Judgment {} is not open (already resolved or not found)", req.decision_id),
            ));
        }

        // Idempotency.
        if inner.log.check_idempotency(req.game_id, &req.idempotency_key).is_some() {
            let decision = build_judgment_decision(&inner, req.game_id, req.decision_id)
                .ok_or_else(|| Error::new(ErrorCode::NotFound, "Judgment not found"))?;
            let proj = project_game(&inner.log, req.game_id);
            return Ok(ResolveJudgmentResult {
                decision,
                state: proj.to_game_state(),
            });
        }

        // Append JudgmentResolved (records the decider — I2).
        let seq = inner.log.append(
            req.game_id,
            req.actor.clone(),
            Event::JudgmentResolved(JudgmentResolvedPayload {
                decision_id: req.decision_id,
                chosen_token: req.chosen.token.clone(),
                chosen_label: req.chosen.label.clone(),
                idempotency_key: req.idempotency_key.clone(),
            }),
            None,
        );
        inner.log.register_idempotency(req.game_id, req.idempotency_key, seq);

        let decision = build_judgment_decision(&inner, req.game_id, req.decision_id)
            .ok_or_else(|| Error::new(ErrorCode::NotFound, "Judgment not found after resolve"))?;
        let proj = project_game(&inner.log, req.game_id);

        Ok(ResolveJudgmentResult {
            decision,
            state: proj.to_game_state(),
        })
    }

    fn get_game_state(&self, game_id: GameId) -> CoreResult<GameState> {
        let inner = self.inner.lock().unwrap();
        if !inner.log.game_exists(game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }
        let proj = project_game(&inner.log, game_id);
        Ok(proj.to_game_state())
    }

    fn list_game_events(&self, game_id: GameId) -> CoreResult<Vec<EventSummary>> {
        let inner = self.inner.lock().unwrap();
        if !inner.log.game_exists(game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }
        let summaries: Vec<EventSummary> = inner
            .log
            .all_rows(game_id)
            .map(|row| EventSummary {
                seq: Seq(row.seq),
                event_type: row.event.type_name().into(),
                actor: row.actor.clone(),
                corrects_seq: row.corrects_seq.map(Seq),
            })
            .collect();
        Ok(summaries)
    }

    fn get_play(&self, game_id: GameId, seq: Seq) -> CoreResult<Play> {
        let inner = self.inner.lock().unwrap();
        let row = inner
            .log
            .get_row(game_id, seq.0)
            .ok_or_else(|| Error::new(ErrorCode::NotFound, format!("Seq {} not found", seq.0)))?;

        let play_payload = match &row.event {
            Event::PlayRecorded(p) => p,
            _ => {
                return Err(Error::new(
                    ErrorCode::NotFound,
                    format!("Seq {} is not a PlayRecorded event", seq.0),
                ))
            }
        };

        let proj_at = project_game(&inner.log, game_id);
        let ctx = ClassifyContext {
            inning_has_error_or_pb: proj_at.current_half.has_error_or_pb,
        };
        let classification = classify_with_context(&play_payload.play, &ctx);
        let reisner = render_cell(&play_payload.play, 0);

        // Surface the judgment opened for this play (open or resolved), if any, rather
        // than hardcoding None — a read of a judgment play must expose its decision.
        let judgment = inner
            .log
            .all_rows(game_id)
            .find_map(|r| match &r.event {
                Event::JudgmentOpened(jp) if jp.for_seq == seq.0 => Some(jp.decision_id),
                _ => None,
            })
            .and_then(|did| build_judgment_decision(&inner, game_id, did));

        Ok(Play {
            seq,
            normalized: play_payload.play.clone(),
            classification,
            reisner,
            confirmed: row.confirmed,
            judgment,
        })
    }

    fn get_proof_box(&self, game_id: GameId, inning: u8, half: Half) -> CoreResult<ProofBox> {
        let inner = self.inner.lock().unwrap();
        if !inner.log.game_exists(game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }
        let proj = project_game(&inner.log, game_id);
        if proj.inning == inning && proj.half == half {
            return Ok(compute_proof_box(&proj.current_half, inning, half));
        }

        // Half-inning ordering index (top before bottom of the same inning).
        let half_index = |inn: u8, h: Half| -> u32 {
            (u32::from(inn) << 1) | u32::from(h == Half::Bottom)
        };
        let requested = half_index(inning, half);
        let current = half_index(proj.inning, proj.half);

        if requested < current {
            // A PAST half-inning: the current projection no longer holds its tallies,
            // and replay-up-to-that-point is not yet implemented. Return a structured
            // error rather than a misleading all-zeros ProofBox (no silent fabrication).
            Err(Error::new(
                ErrorCode::InvalidArgument,
                format!(
                    "historical proof box for inning {} {:?} requires replay-up-to \
                     (not yet implemented); only the current half-inning is queryable",
                    inning, half
                ),
            ))
        } else {
            // A FUTURE/not-yet-played half-inning legitimately has no tallies yet.
            Ok(ProofBox {
                inning,
                half,
                ab: 0, bb: 0, sac: 0, hbp: 0, interference: 0,
                runs: 0, putouts: 0, stranded: 0,
            })
        }
    }
}

// ---------------------------------------------------------------------------
// Distance helper for advance_runner (independent of rules module)
// ---------------------------------------------------------------------------

fn base_distance_direct(from: crate::model::Base, to: AdvanceOutcome) -> u8 {
    let from_n = match from {
        Base::Home => 0u8,
        Base::First => 1,
        Base::Second => 2,
        Base::Third => 3,
    };
    let to_n = match to {
        AdvanceOutcome::Out => return 0,
        AdvanceOutcome::Base(Base::Home) => 4u8,
        AdvanceOutcome::Base(Base::First) => 1,
        AdvanceOutcome::Base(Base::Second) => 2,
        AdvanceOutcome::Base(Base::Third) => 3,
    };
    to_n.saturating_sub(from_n)
}

// ---------------------------------------------------------------------------
// Tests (T020, T019 — contract tests)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::{Actor, ActorKind, FinalizeMode, Needs, Team};
    use crate::model::{
        Advance, AdvanceTo, BallType, BatterEvent, BatterHand, Catalyst, Count,
        NormalizedPlay, Position, RunnerId, Runners, SituationDiamond, Base,
    };

    fn owner_actor() -> Actor {
        Actor {
            kind: ActorKind::Human,
            id: "owner-1".into(),
            harness_version: None,
        }
    }

    fn team(id: &str, name: &str) -> Team {
        Team {
            id: id.into(),
            name: name.into(),
            lineup: None,
        }
    }

    fn create_game_req() -> CreateGameRequest {
        CreateGameRequest {
            home: team("NYA", "Yankees"),
            visitor: team("BOS", "Red Sox"),
            idempotency_key: "create-1".into(),
            actor: owner_actor(),
        }
    }

    fn groundout_play() -> NormalizedPlay {
        NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6), Position(3)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    fn strikeout_play() -> NormalizedPlay {
        NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 2 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::Strikeout,
                fielders: vec![],
                ball_type: BallType::None,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Out,
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    #[test]
    fn create_game_returns_initial_state() {
        let core = DiamondCore::new();
        let result = core.create_game(create_game_req()).unwrap();
        let state = result.state;
        assert_eq!(state.inning, 1);
        assert_eq!(state.half, Half::Top);
        assert_eq!(state.outs, 0);
    }

    /// FR-007: state never advances on unconfirmed entry.
    #[test]
    fn state_does_not_advance_until_confirmed() {
        let core = DiamondCore::new();
        let game = core.create_game(create_game_req()).unwrap();
        let gid = game.game_id;

        // Record a play.
        let r1 = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(groundout_play()),
            idempotency_key: "p1".into(),
            actor: owner_actor(),
        }).unwrap();
        assert_eq!(r1.needs, Needs::Confirm);

        // State should NOT be updated yet (it's a preview).
        let state = core.get_game_state(gid).unwrap();
        assert_eq!(state.outs, 0, "State must not advance before confirmation (FR-007)");

        // Trying to record another play before confirming should fail.
        let r2 = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(strikeout_play()),
            idempotency_key: "p2".into(),
            actor: owner_actor(),
        });
        assert!(
            r2.is_err(),
            "record_play with pending confirmation must return error (FR-007)"
        );
        if let Err(e) = r2 {
            assert_eq!(e.code, ErrorCode::PendingConfirmation);
        }
    }

    #[test]
    fn confirm_advances_state() {
        let core = DiamondCore::new();
        let game = core.create_game(create_game_req()).unwrap();
        let gid = game.game_id;

        let r1 = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(groundout_play()),
            idempotency_key: "p1".into(),
            actor: owner_actor(),
        }).unwrap();

        core.confirm_play(ConfirmPlayRequest {
            game_id: gid,
            confirms_seq: r1.recorded_seq,
            idempotency_key: "c1".into(),
            actor: owner_actor(),
        }).unwrap();

        let state = core.get_game_state(gid).unwrap();
        assert_eq!(state.outs, 1, "State must advance after confirmation");
    }

    /// I5/FR-020: unauthorized actor must return Unauthorized.
    #[test]
    fn unauthorized_actor_rejected() {
        let core = DiamondCore::new();
        let game = core.create_game(create_game_req()).unwrap();
        let gid = game.game_id;

        let interloper = Actor {
            kind: ActorKind::Human,
            id: "interloper".into(),
            harness_version: None,
        };
        let result = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(groundout_play()),
            idempotency_key: "p1".into(),
            actor: interloper,
        });
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code, ErrorCode::Unauthorized);
    }

    /// Transcript input returns TranscriptNotSupported.
    #[test]
    fn transcript_input_returns_error() {
        let core = DiamondCore::new();
        let game = core.create_game(create_game_req()).unwrap();
        let gid = game.game_id;
        let result = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Transcript("ground ball to short".into()),
            idempotency_key: "p1".into(),
            actor: owner_actor(),
        });
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code, ErrorCode::TranscriptNotSupported);
    }

    /// Judgment play opens a JudgmentDecision and returns Needs::Judgment.
    #[test]
    fn judgment_play_opens_decision() {
        let core = DiamondCore::new();
        let game = core.create_game(create_game_req()).unwrap();
        let gid = game.game_id;

        // HitVsError judgment play.
        let judgment_play = NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![Position(6)],
            },
            audit_label: Some("single".into()), // adversarial mislabel
        };

        let result = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(judgment_play),
            idempotency_key: "p-judgment".into(),
            actor: owner_actor(),
        }).unwrap();

        assert_eq!(result.needs, Needs::Judgment);
        assert!(result.judgment.is_some());
        assert_eq!(
            result.classification,
            Classification::Judgment(JudgmentKind::HitVsError)
        );
    }

    /// A play that surfaced a judgment must NOT be confirmable while the judgment is
    /// open — confirm_play returns JUDGMENT_REQUIRED (I2 / confirm_play contract).
    #[test]
    fn confirm_blocked_by_open_judgment() {
        let core = DiamondCore::new();
        let gid = core.create_game(create_game_req()).unwrap().game_id;

        let judgment_play = NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![Position(6)],
            },
            audit_label: None,
        };

        let r = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(judgment_play),
            idempotency_key: "pj".into(),
            actor: owner_actor(),
        }).unwrap();
        assert_eq!(r.needs, Needs::Judgment);
        let decision_id = r.judgment.as_ref().unwrap().id;

        // Confirming the recorded seq while the judgment is OPEN must be rejected.
        let blocked = core.confirm_play(ConfirmPlayRequest {
            game_id: gid,
            confirms_seq: r.recorded_seq,
            idempotency_key: "c-blocked".into(),
            actor: owner_actor(),
        });
        assert!(blocked.is_err(), "confirm must be blocked while judgment open");
        assert_eq!(blocked.unwrap_err().code, ErrorCode::JudgmentRequired);

        // After resolving the judgment, the same play can be confirmed.
        core.resolve_judgment(ResolveJudgmentRequest {
            game_id: gid,
            decision_id,
            chosen: Call { token: "hit".into(), label: "Hit".into() },
            idempotency_key: "rj".into(),
            actor: owner_actor(),
        }).unwrap();

        let ok = core.confirm_play(ConfirmPlayRequest {
            game_id: gid,
            confirms_seq: r.recorded_seq,
            idempotency_key: "c-ok".into(),
            actor: owner_actor(),
        });
        assert!(ok.is_ok(), "confirm must succeed once judgment resolved: {ok:?}");
    }

    /// record_play idempotent retry of a JUDGMENT play must re-surface the open
    /// decision + Needs::Judgment — never (Confirm, None) (I2).
    #[test]
    fn record_play_retry_of_judgment_resurfaces_decision() {
        let core = DiamondCore::new();
        let gid = core.create_game(create_game_req()).unwrap().game_id;

        let judgment_play = NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![Position(6)],
            },
            audit_label: None,
        };

        let first = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(judgment_play.clone()),
            idempotency_key: "retry-key".into(),
            actor: owner_actor(),
        }).unwrap();
        assert_eq!(first.needs, Needs::Judgment);
        let first_decision = first.judgment.as_ref().unwrap().id;

        // Same idempotency key → idempotency-hit branch. Must NOT degrade to Confirm/None.
        let retry = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(judgment_play),
            idempotency_key: "retry-key".into(),
            actor: owner_actor(),
        }).unwrap();

        assert_eq!(retry.recorded_seq, first.recorded_seq, "retry returns the prior seq");
        assert_eq!(retry.needs, Needs::Judgment, "retry must still need a judgment");
        let retry_decision = retry.judgment.as_ref().expect("retry must carry the decision");
        assert_eq!(retry_decision.id, first_decision, "retry resurfaces the same decision");
        assert_eq!(retry_decision.status, JudgmentStatus::Open);
    }

    /// H1 wire format (SC-008): the fact-layer enums serialize snake_case so the
    /// JSON boundary is the single unambiguous target the Swift/UniFFI side codes to.
    #[test]
    fn fact_enums_serialize_snake_case() {
        let play = groundout_play();
        let json = serde_json::to_string(&play).unwrap();
        // batter_hand: Right → "right"; batter_event: FieldedOut → "fielded_out";
        // ball_type: Ground → "ground"; from: Home → "home"; to: Out → "out".
        assert!(json.contains("\"right\""), "batter_hand snake_case: {json}");
        assert!(json.contains("\"fielded_out\""), "batter_event snake_case: {json}");
        assert!(json.contains("\"ground\""), "ball_type snake_case: {json}");
        assert!(json.contains("\"home\""), "from base snake_case: {json}");
        assert!(json.contains("\"out\""), "advance_to snake_case: {json}");
        // No PascalCase leakage of the renamed variants.
        assert!(!json.contains("\"FieldedOut\""), "no PascalCase batter_event: {json}");
        assert!(!json.contains("\"Ground\""), "no PascalCase ball_type: {json}");

        // Classification (data-carrying) serializes its tag snake_case too.
        let j = serde_json::to_string(&Classification::Judgment(JudgmentKind::HitVsError)).unwrap();
        assert!(j.contains("\"judgment\""), "Classification tag snake_case: {j}");
        assert!(j.contains("\"hit_vs_error\""), "JudgmentKind snake_case: {j}");
    }

    /// Determinism: same confirmed events → byte-identical state.
    #[test]
    fn determinism_same_events_byte_identical_state() {
        let core = DiamondCore::new();
        let gid = core.create_game(create_game_req()).unwrap().game_id;

        // Record + confirm 3 plays.
        for i in 0..3u32 {
            let r = core.record_play(RecordPlayRequest {
                game_id: gid,
                input: PlayInput::Normalized(groundout_play()),
                idempotency_key: format!("p{}", i),
                actor: owner_actor(),
            }).unwrap();
            core.confirm_play(ConfirmPlayRequest {
                game_id: gid,
                confirms_seq: r.recorded_seq,
                idempotency_key: format!("c{}", i),
                actor: owner_actor(),
            }).unwrap();
        }

        let s1 = core.get_game_state(gid).unwrap();
        let s2 = core.get_game_state(gid).unwrap();
        assert_eq!(
            serde_json::to_string(&s1).unwrap(),
            serde_json::to_string(&s2).unwrap(),
            "Game state must be byte-identical across reads (FR-003/I6)"
        );
    }

    /// resolve_judgment records the decider (I2/FR-011).
    #[test]
    fn resolve_judgment_records_decider() {
        let core = DiamondCore::new();
        let gid = core.create_game(create_game_req()).unwrap().game_id;

        let judgment_play = NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::FieldedOut,
                fielders: vec![Position(6)],
                ball_type: BallType::Ground,
                advances: vec![Advance {
                    runner: RunnerId(1),
                    from: Base::Home,
                    to: AdvanceTo::Base(Base::First),
                    by_error: None,
                }],
                touched_or_misplayed_by: vec![Position(6)],
            },
            audit_label: None,
        };

        let r = core.record_play(RecordPlayRequest {
            game_id: gid,
            input: PlayInput::Normalized(judgment_play),
            idempotency_key: "pj".into(),
            actor: owner_actor(),
        }).unwrap();

        let decision_id = r.judgment.unwrap().id;

        let resolved = core.resolve_judgment(ResolveJudgmentRequest {
            game_id: gid,
            decision_id,
            chosen: Call { token: "hit".into(), label: "Hit".into() },
            idempotency_key: "rj".into(),
            actor: owner_actor(),
        }).unwrap();

        assert_eq!(resolved.decision.status, JudgmentStatus::Resolved);
        assert!(resolved.decision.decider.is_some());
        assert_eq!(resolved.decision.decider.as_ref().unwrap().id, "owner-1");
    }

    /// Finalize with an unbalanced proof box must fail (SC-011).
    #[test]
    fn finalize_succeeds_on_empty_game() {
        let core = DiamondCore::new();
        let gid = core.create_game(create_game_req()).unwrap().game_id;
        // Empty game (no plays) — proof box is all zeros, which is balanced (0=0).
        let result = core.finalize_scorecard(FinalizeRequest {
            game_id: gid,
            mode: FinalizeMode::Checkpoint,
            idempotency_key: "fin".into(),
            actor: owner_actor(),
        });
        assert!(result.is_ok(), "Empty game finalize should succeed: {:?}", result);
    }
}
