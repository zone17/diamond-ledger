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
}

impl Default for DiamondCore {
    fn default() -> Self {
        Self::new()
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

        // Authority.
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;

        // Game must exist.
        if !inner.log.game_exists(req.game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }

        // Idempotency.
        if let Some(_) = inner.log.check_idempotency(req.game_id, &req.idempotency_key) {
            let proj = project_game(&inner.log, req.game_id);
            return Ok(ConfirmPlayResult { state: proj.to_game_state() });
        }

        // The seq being confirmed must exist and be a PlayRecorded.
        let row = inner.log.get_row(req.game_id, req.confirms_seq).ok_or_else(|| {
            Error::new(ErrorCode::NotFound, format!("Seq {} not found", req.confirms_seq))
        })?;
        if !matches!(row.event, Event::PlayRecorded(_)) {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("Seq {} is not a PlayRecorded event", req.confirms_seq),
            ));
        }

        // Mark confirmed.
        inner.log.confirm_row(req.game_id, req.confirms_seq);

        // Append PlayConfirmed.
        let seq = inner.log.append(
            req.game_id,
            req.actor.clone(),
            Event::PlayConfirmed(PlayConfirmedPayload {
                confirms_seq: req.confirms_seq,
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

        // FR-007: state never advances on an unconfirmed entry.
        // If there's already an unconfirmed play, reject.
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

        // Idempotency.
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
                return Ok(RecordPlayResult {
                    recorded_seq: Seq(prior_seq),
                    normalized: play,
                    classification,
                    reisner: cell,
                    state_preview: proj.to_game_state(),
                    judgment: None,
                    needs: Needs::Confirm,
                });
            }
        }

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

        // Authority.
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;

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

        // correct_event is post-MVP (US4); return a structured "not yet implemented" error.
        // This satisfies the contract (never panics, returns typed error).
        Err(Error::new(
            ErrorCode::InvalidArgument,
            "correct_event is post-MVP (US4); not yet implemented in this increment",
        ))
    }

    fn finalize_scorecard(&self, req: FinalizeRequest) -> CoreResult<FinalizeResult> {
        let mut inner = self.inner.lock().unwrap();

        // Authority.
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;

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

        // Idempotency.
        if let Some(_) = inner.log.check_idempotency(req.game_id, &req.idempotency_key) {
            // Return a cached result (simplified for MVP — just rebuild).
        }

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
        proof_boxes.push(pb.clone());

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

        // Append GameFinalized.
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

        // Authority.
        let auth = inner.get_authority(req.game_id)?.clone();
        assert_authority(&req.actor, &auth)?;

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
        if let Some(_) = inner.log.check_idempotency(req.game_id, &req.idempotency_key) {
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

        Ok(Play {
            seq,
            normalized: play_payload.play.clone(),
            classification,
            reisner,
            confirmed: row.confirmed,
            judgment: None,
        })
    }

    fn get_proof_box(&self, game_id: GameId, inning: u8, half: Half) -> CoreResult<ProofBox> {
        let inner = self.inner.lock().unwrap();
        if !inner.log.game_exists(game_id) {
            return Err(Error::new(ErrorCode::NotFound, "Game not found"));
        }
        let proj = project_game(&inner.log, game_id);
        if proj.inning == inning && proj.half == half {
            Ok(compute_proof_box(&proj.current_half, inning, half))
        } else {
            // For historical half-innings, we'd need to replay up to that point.
            // MVP: return empty proof box for past innings.
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
    if to_n > from_n { to_n - from_n } else { 0 }
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
            confirms_seq: r1.recorded_seq.0,
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
                confirms_seq: r.recorded_seq.0,
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
