//! Append-only event log with monotonic sequence numbers and deterministic replay (T013).
//!
//! Same confirmed event sequence → byte-identical projected state (FR-003/I6).
//! `PlayRecorded` rows start unconfirmed; state advances only on `PlayConfirmed` (FR-007).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::ffi::{Actor, FinalizeMode, GameId};
use crate::model::{AdvanceTo, Base, BatterEvent, JudgmentKind, NormalizedPlay, Position};

// ---------------------------------------------------------------------------
// Event types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event_type", content = "payload")]
pub enum Event {
    GameStarted(GameStartedPayload),
    PlayRecorded(PlayRecordedPayload),
    PlayConfirmed(PlayConfirmedPayload),
    JudgmentOpened(JudgmentOpenedPayload),
    JudgmentResolved(JudgmentResolvedPayload),
    RunnerAdvanced(RunnerAdvancedPayload),
    EventCorrected(EventCorrectedPayload),
    GameFinalized(GameFinalizedPayload),
}

impl Event {
    pub fn type_name(&self) -> &'static str {
        match self {
            Event::GameStarted(_) => "GameStarted",
            Event::PlayRecorded(_) => "PlayRecorded",
            Event::PlayConfirmed(_) => "PlayConfirmed",
            Event::JudgmentOpened(_) => "JudgmentOpened",
            Event::JudgmentResolved(_) => "JudgmentResolved",
            Event::RunnerAdvanced(_) => "RunnerAdvanced",
            Event::EventCorrected(_) => "EventCorrected",
            Event::GameFinalized(_) => "GameFinalized",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameStartedPayload {
    pub home_team_id: String,
    pub home_team_name: String,
    pub visitor_team_id: String,
    pub visitor_team_name: String,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayRecordedPayload {
    pub play: NormalizedPlay,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayConfirmedPayload {
    pub confirms_seq: u64,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JudgmentOpenedPayload {
    pub decision_id: u64,
    pub kind: JudgmentKind,
    pub for_seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JudgmentResolvedPayload {
    pub decision_id: u64,
    pub chosen_token: String,
    pub chosen_label: String,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunnerAdvancedPayload {
    pub runner_id: u32,
    pub from: Base,
    pub to: AdvanceTo,
    pub by_error: Option<Position>,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventCorrectedPayload {
    pub corrects_seq: u64,
    pub amended_play: NormalizedPlay,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameFinalizedPayload {
    pub mode: FinalizeMode,
    pub idempotency_key: String,
}

// ---------------------------------------------------------------------------
// Log row
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogRow {
    pub seq: u64,
    pub game_id: GameId,
    pub actor: Actor,
    pub event: Event,
    /// Only `PlayRecorded` starts unconfirmed (FR-007).
    pub confirmed: bool,
    pub corrects_seq: Option<u64>,
}

// ---------------------------------------------------------------------------
// EventLog
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
pub struct EventLog {
    games: HashMap<u64, Vec<LogRow>>,
    idempotency: HashMap<u64, HashMap<String, u64>>,
    judgment_counters: HashMap<u64, u64>,
    game_id_counter: u64,
}

impl EventLog {
    pub fn new() -> Self {
        Self::default()
    }

    /// Append a new event; returns the assigned seq.
    pub fn append(
        &mut self,
        game_id: GameId,
        actor: Actor,
        event: Event,
        corrects_seq: Option<u64>,
    ) -> u64 {
        let rows = self.games.entry(game_id.0).or_default();
        let seq = rows.len() as u64;
        let confirmed = !matches!(event, Event::PlayRecorded(_));
        rows.push(LogRow {
            seq,
            game_id,
            actor,
            event,
            confirmed,
            corrects_seq,
        });
        seq
    }

    pub fn check_idempotency(&self, game_id: GameId, key: &str) -> Option<u64> {
        self.idempotency
            .get(&game_id.0)
            .and_then(|c| c.get(key).copied())
    }

    pub fn register_idempotency(&mut self, game_id: GameId, key: String, seq: u64) {
        self.idempotency
            .entry(game_id.0)
            .or_default()
            .insert(key, seq);
    }

    /// Mark a `PlayRecorded` row as confirmed. Returns true on success.
    pub fn confirm_row(&mut self, game_id: GameId, seq: u64) -> bool {
        let rows = match self.games.get_mut(&game_id.0) {
            Some(r) => r,
            None => return false,
        };
        if let Some(row) = rows.get_mut(seq as usize) {
            if matches!(row.event, Event::PlayRecorded(_)) && row.seq == seq {
                row.confirmed = true;
                return true;
            }
        }
        false
    }

    pub fn all_rows(&self, game_id: GameId) -> impl Iterator<Item = &LogRow> {
        self.games
            .get(&game_id.0)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
            .iter()
    }

    pub fn confirmed_rows(&self, game_id: GameId) -> impl Iterator<Item = &LogRow> {
        self.all_rows(game_id).filter(|r| r.confirmed)
    }

    pub fn pending_play(&self, game_id: GameId) -> Option<&LogRow> {
        self.games.get(&game_id.0)?.iter().rev().find(|r| {
            matches!(r.event, Event::PlayRecorded(_)) && !r.confirmed
        })
    }

    pub fn get_row(&self, game_id: GameId, seq: u64) -> Option<&LogRow> {
        self.games
            .get(&game_id.0)
            .and_then(|rows| rows.get(seq as usize))
    }

    pub fn next_judgment_id(&mut self, game_id: GameId) -> u64 {
        let counter = self.judgment_counters.entry(game_id.0).or_insert(0);
        let id = *counter;
        *counter += 1;
        id
    }

    pub fn game_exists(&self, game_id: GameId) -> bool {
        self.games
            .get(&game_id.0)
            .map_or(false, |v| !v.is_empty())
    }

    pub fn allocate_game_id(&mut self) -> GameId {
        self.game_id_counter += 1;
        GameId(self.game_id_counter)
    }

    pub fn open_judgments(&self, game_id: GameId) -> Vec<u64> {
        let mut opened: std::collections::HashSet<u64> = std::collections::HashSet::new();
        let mut resolved: std::collections::HashSet<u64> = std::collections::HashSet::new();
        for row in self.all_rows(game_id) {
            match &row.event {
                Event::JudgmentOpened(p) => { opened.insert(p.decision_id); }
                Event::JudgmentResolved(p) => { resolved.insert(p.decision_id); }
                _ => {}
            }
        }
        let mut out: Vec<u64> = opened.difference(&resolved).copied().collect();
        out.sort_unstable();
        out
    }

    pub fn get_judgment_opened(
        &self,
        game_id: GameId,
        decision_id: u64,
    ) -> Option<&JudgmentOpenedPayload> {
        for row in self.all_rows(game_id) {
            if let Event::JudgmentOpened(p) = &row.event {
                if p.decision_id == decision_id {
                    return Some(p);
                }
            }
        }
        None
    }

    pub fn get_judgment_resolved(
        &self,
        game_id: GameId,
        decision_id: u64,
    ) -> Option<&JudgmentResolvedPayload> {
        for row in self.all_rows(game_id) {
            if let Event::JudgmentResolved(p) = &row.event {
                if p.decision_id == decision_id {
                    return Some(p);
                }
            }
        }
        None
    }

    /// Check if any play in a list has an error or passed ball (half-inning context).
    pub fn plays_have_error_or_pb(plays: &[NormalizedPlay]) -> bool {
        for play in plays {
            if play.catalyst.batter_event == BatterEvent::Error
                || play.catalyst.batter_event == BatterEvent::PassedBall
            {
                return true;
            }
            for adv in &play.catalyst.advances {
                if adv.by_error.is_some() {
                    return true;
                }
            }
        }
        false
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::{ActorKind, GameId};
    use crate::model::{
        BallType, BatterHand, Catalyst, Count, Runners, SituationDiamond,
    };

    fn dummy_actor() -> Actor {
        Actor {
            kind: ActorKind::Human,
            id: "owner-1".into(),
            harness_version: None,
        }
    }

    fn dummy_play() -> NormalizedPlay {
        NormalizedPlay {
            situation: SituationDiamond {
                runners: Runners::default(),
                outs: 0,
                count: Count { balls: 0, strikes: 0 },
                batter_hand: BatterHand::Right,
            },
            catalyst: Catalyst {
                batter_event: BatterEvent::Strikeout,
                fielders: vec![],
                ball_type: BallType::None,
                advances: vec![],
                touched_or_misplayed_by: vec![],
            },
            audit_label: None,
        }
    }

    #[test]
    fn seq_is_monotonic() {
        let mut log = EventLog::new();
        let gid = GameId(1);
        let s0 = log.append(
            gid, dummy_actor(),
            Event::GameStarted(GameStartedPayload {
                home_team_id: "A".into(), home_team_name: "A".into(),
                visitor_team_id: "B".into(), visitor_team_name: "B".into(),
                idempotency_key: "ik0".into(),
            }), None,
        );
        let s1 = log.append(
            gid, dummy_actor(),
            Event::PlayRecorded(PlayRecordedPayload {
                play: dummy_play(), idempotency_key: "ik1".into(),
            }), None,
        );
        assert_eq!(s0, 0);
        assert_eq!(s1, 1);
    }

    #[test]
    fn play_recorded_starts_unconfirmed() {
        let mut log = EventLog::new();
        let gid = GameId(1);
        let seq = log.append(
            gid, dummy_actor(),
            Event::PlayRecorded(PlayRecordedPayload {
                play: dummy_play(), idempotency_key: "ik1".into(),
            }), None,
        );
        assert!(!log.get_row(gid, seq).unwrap().confirmed);
    }

    #[test]
    fn confirm_row_works() {
        let mut log = EventLog::new();
        let gid = GameId(1);
        let seq = log.append(
            gid, dummy_actor(),
            Event::PlayRecorded(PlayRecordedPayload {
                play: dummy_play(), idempotency_key: "ik1".into(),
            }), None,
        );
        assert!(log.confirm_row(gid, seq));
        assert!(log.get_row(gid, seq).unwrap().confirmed);
    }

    /// T016 / FR-003 / I6: replay twice → byte-identical.
    #[test]
    fn determinism_replay_twice_identical() {
        let mut log = EventLog::new();
        let gid = GameId(42);
        log.append(gid, dummy_actor(),
            Event::GameStarted(GameStartedPayload {
                home_team_id: "NYA".into(), home_team_name: "Yankees".into(),
                visitor_team_id: "BOS".into(), visitor_team_name: "Red Sox".into(),
                idempotency_key: "ik-start".into(),
            }), None);
        let s1 = log.append(gid, dummy_actor(),
            Event::PlayRecorded(PlayRecordedPayload {
                play: dummy_play(), idempotency_key: "ik-p1".into(),
            }), None);
        log.confirm_row(gid, s1);
        let s2 = log.append(gid, dummy_actor(),
            Event::PlayRecorded(PlayRecordedPayload {
                play: dummy_play(), idempotency_key: "ik-p2".into(),
            }), None);
        log.confirm_row(gid, s2);

        let rows1: Vec<_> = log.confirmed_rows(gid).cloned().collect();
        let rows2: Vec<_> = log.confirmed_rows(gid).cloned().collect();
        assert_eq!(
            serde_json::to_string(&rows1).unwrap(),
            serde_json::to_string(&rows2).unwrap(),
            "Replay must be byte-identical (FR-003/I6)"
        );
    }

    #[test]
    fn non_play_events_immediately_confirmed() {
        let mut log = EventLog::new();
        let gid = GameId(1);
        let seq = log.append(gid, dummy_actor(),
            Event::GameStarted(GameStartedPayload {
                home_team_id: "A".into(), home_team_name: "A".into(),
                visitor_team_id: "B".into(), visitor_team_name: "B".into(),
                idempotency_key: "ik".into(),
            }), None);
        assert!(log.get_row(gid, seq).unwrap().confirmed);
    }
}
