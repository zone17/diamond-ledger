//! Owner-as-decider authority enforcement (T036, I5/FR-020).
//!
//! Every primitive asserts authority before appending any event. In v1 the model is
//! "owner-as-decider": the authenticated owner (or an explicitly authorized agent) is the
//! only valid caller. Multi-role/org permissions are deferred (FR-020).

use crate::ffi::{Actor, Error, ErrorCode};

/// The authority model for a game (v1: owner id + authorized agent ids).
#[derive(Debug, Clone)]
pub struct GameAuthority {
    /// The owner id who created the game.
    pub owner_id: String,
    /// Explicitly authorized agent ids (empty by default).
    pub authorized_agents: Vec<String>,
}

impl GameAuthority {
    pub fn new(owner_id: impl Into<String>) -> Self {
        GameAuthority {
            owner_id: owner_id.into(),
            authorized_agents: Vec::new(),
        }
    }
}

/// Assert that the caller has authority for the game.
///
/// Returns `Ok(())` if the actor is the owner or an authorized agent;
/// returns `Err(Error { code: Unauthorized, … })` otherwise.
///
/// This is called at every primitive boundary (I5/FR-020/T036) before any event append.
pub fn assert_authority(actor: &Actor, auth: &GameAuthority) -> Result<(), Error> {
    if actor.id == auth.owner_id {
        return Ok(());
    }
    if auth.authorized_agents.contains(&actor.id) {
        return Ok(());
    }
    Err(Error::new(
        ErrorCode::Unauthorized,
        format!(
            "Actor '{}' is not the game owner or an authorized agent (I5/FR-020)",
            actor.id
        ),
    ))
}

/// Assert that the actor id is non-trivial (non-empty, non-placeholder).
///
/// This catches callers that pass an empty or clearly fake identity (FR-020).
pub fn assert_nontrivial_identity(actor: &Actor) -> Result<(), Error> {
    let id = actor.id.trim();
    if id.is_empty() || id == "anonymous" || id == "unknown" {
        return Err(Error::new(
            ErrorCode::Unauthorized,
            format!(
                "Actor identity '{}' is trivial — a real owner identity is required (FR-020)",
                actor.id
            ),
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests (T036)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::{ActorKind};

    fn actor(id: &str) -> Actor {
        Actor {
            kind: ActorKind::Human,
            id: id.into(),
            harness_version: None,
        }
    }

    #[test]
    fn owner_is_authorized() {
        let auth = GameAuthority::new("owner-1");
        assert!(assert_authority(&actor("owner-1"), &auth).is_ok());
    }

    #[test]
    fn non_owner_is_unauthorized() {
        let auth = GameAuthority::new("owner-1");
        assert!(assert_authority(&actor("attacker"), &auth).is_err());
    }

    #[test]
    fn authorized_agent_is_allowed() {
        let mut auth = GameAuthority::new("owner-1");
        auth.authorized_agents.push("agent-007".into());
        assert!(assert_authority(&actor("agent-007"), &auth).is_ok());
    }

    #[test]
    fn empty_identity_rejected() {
        assert!(assert_nontrivial_identity(&actor("")).is_err());
        assert!(assert_nontrivial_identity(&actor("anonymous")).is_err());
        assert!(assert_nontrivial_identity(&actor("owner-real")).is_ok());
    }

    #[test]
    fn unauthorized_returns_correct_error_code() {
        let auth = GameAuthority::new("owner-1");
        let err = assert_authority(&actor("interloper"), &auth).unwrap_err();
        assert_eq!(err.code, ErrorCode::Unauthorized);
    }
}
