# SABR / Retrosheet Outreach — Draft Emails + Brief

**Task**: T066 (Story C5 #108 / issues #109, #110)  
**Authority**: `specs/001-voice-scorebook-core/research.md` D6 · ADR-0006 distribution tripwire  
**Status**: DRAFTS — review before sending. Sending and follow-up is a HUMAN task.  
**Last updated**: 2026-06-02

---

## Context

Diamond Ledger is a voice-driven scorebook app targeting the serious/official scorekeeper
(travel/HS/college statistician, Retrosheet/SABR archivist). The accuracy gates (SC-001 ≥90% play-type,
SC-002 ≥85% Reisner token) are not field-credible until **independently hand-scored gold games exist**.

The primary gold game (MLB Retrosheet source) gives us the harness. But the **beachhead is amateur/
college/MiLB play**, not MLB. SABR outreach recruits the scorers who can co-produce **amateur gold games**
— the data that actually validates the system for its target users.

There are two separate outreach tracks:
1. **SABR Official Scoring Research Committee + Retrosheet** — relationship-building + data collaboration
2. **~20 serious-scorer demo cohort** — ADR-0006 first-slice demand tripwire (separate doc: `demo-cohort-tracker.md`)

---

## Track 1A — Retrosheet (Tom Thress)

### Background

Tom Thress is the founder and primary maintainer of Retrosheet (retrosheet.org), the definitive free
database of MLB play-by-play data. Retrosheet data is already free for commercial use with attribution
([retrosheet.org/notice.txt](https://www.retrosheet.org/notice.txt)) — the relationship here is
**cooperative, not transactional**. Goals:

1. Introduce the project and the Retrosheet-compatible export format.
2. Confirm the attribution string is correct for commercial use.
3. Ask if Retrosheet has contacts for active amateur/college official scorers willing to co-produce gold data.
4. Plant the seed for a longer-term partnership (Retrosheet's mission is preserving baseball records;
   Diamond Ledger's export format is Retrosheet-compatible by design).

### Contact information

- **Name**: Tom Thress
- **Role**: Retrosheet founder / lead
- **Organization**: Retrosheet (retrosheet.org)
- **Contact form**: https://www.retrosheet.org/contact.htm
- **SABR group connection**: Tom Thress is active in SABR records committees

### Draft email — Retrosheet introduction

---

**Subject**: Diamond Ledger — Retrosheet-compatible voice scorebook (beachhead: serious scorers; export format compatible with your standard)

Dear Tom,

I'm building Diamond Ledger, a voice-driven scorebook app targeting serious and official scorekeepers
at the travel baseball, high school, college, and minor league levels — the same community that has
been the backbone of Retrosheet's data contributions for decades.

The app works like this: a scorer speaks plays aloud ("ground ball to short, threw him out at first"),
and the system produces deterministic Reisner notation and exports a Retrosheet-compatible event file
(`.EVN` format, validated against Chadwick `cwevent` v0.10.0). Judgment calls (hit vs. error, etc.)
are surfaced explicitly — never silently decided — as a one-tap scorer decision. The v1 grammar is
*designed* to cover roughly 95% of plays in a typical amateur/college game — a design target we have
not yet validated against a real game corpus, which is exactly where your help would matter.

I'm writing for three reasons:

**1. Attribution confirmation.** I've read the Retrosheet notice.txt carefully and our codebase
includes the required attribution verbatim in every exported file:

> "Data based on the Retrosheet event-file format (retrosheet.org). Use of Retrosheet data is
> subject to the terms at retrosheet.org/notice.txt."

I want to make sure this language is correct for a commercial app that uses Retrosheet's
*event-file format* (not redistribution of Retrosheet's data itself). If there's a preferred
attribution form for commercial implementations of the format, please let me know.

**2. Accuracy validation.** My eval harness uses published Retrosheet `.EVN` files as regression
fixtures — they prove format conformance, not field accuracy. For the field-accuracy gates, I need
**independently hand-scored amateur/college games** with audio narration and Reisner scoring. If you
know active official scorers at the amateur or MiLB level who might be willing to co-produce 2–3
gold games for this purpose (15–20 games' worth of plays, compensated or credited per their
preference), I would be very grateful for an introduction.

**3. Long-term alignment.** Diamond Ledger's export format is a direct implementation of the
Retrosheet reduced grammar, which means every game scored becomes a potential contribution to
historical record-keeping at a quality level previously limited to MLB. If the app gains adoption
among serious scorers, it could meaningfully expand the universe of Retrosheet-quality records
beyond MLB.

I'd love a brief call or email exchange if you're interested. Happy to share the spec and the
reduced-grammar contract document.

Thank you for the decades of work that made Retrosheet's dataset the gold standard it is.

Matt Wollschleger  
Diamond Ledger  
[contact info]

---

### Notes on this draft

- Retrosheet's primary concern is correct attribution and non-abuse of their data.
  The email addresses this proactively (paragraph 1).
- The "amateur gold game" ask (paragraph 2) is the real operational need; frame it as a
  favor/collaboration, not a request for Retrosheet's data.
- Keep the tone technical and peer-to-peer — Tom Thress is an engineer and a statistician.
- **Do not send until the attribution string is confirmed with legal counsel or the project lead.**
- **Follow-up cadence**: if no response in 2 weeks, one polite follow-up via the contact form.

---

## Track 1B — SABR Official Scoring Research Committee

### Background

The SABR Official Scoring Research Committee (sabrgroups.org/g/official-scoring) is a research group
within the Society for American Baseball Research focused on official scoring decisions, rule
interpretations, and historical scoring records. Members include:

- Active MLB official scorers (the community of MLB-credentialed official scorers — roughly two to three on rotation per club)
- College and minor league official scorers
- Baseball researchers and statisticians with deep scoring expertise

This is the **highest-value path for recruiting 2–3 active scorers** to co-produce amateur gold
games — the beachhead population. A SABR member who is also an official scorer has exactly the
skills needed (Reisner notation, Retrosheet-compatible event files, judgment-call expertise).

### Contact information

- **Group page**: https://sabr.org/research/official-scoring-research-committee/
- **Group mailing list**: sabrgroups.org → Official Scoring Research Committee → join and post
- **SABR national contact**: info@sabr.org (for intro; ask to be connected to the committee chair)
- **Find the chair**: the committee chair changes; check the current chair at
  https://sabr.org/research-committee/ → "Official Scoring Research Committee"

### Draft email — SABR committee introduction

---

**Subject**: Diamond Ledger — voice-driven scorebook seeking active scorer collaborators (2–3 gold game co-producers)

Dear [SABR Official Scoring Research Committee Chair / Committee Members],

My name is Matt Wollschleger and I am building Diamond Ledger, a voice-driven baseball scorebook
targeting serious and official scorekeepers at the travel, high school, college, and minor league
levels.

**What the app does:** a scorer speaks plays ("fly ball to right, caught at the wall") and the
system produces Reisner notation and exports a Retrosheet-compatible event file, validated against
pinned Chadwick `cwevent` v0.10.0. Judgment calls (hit vs. error, earned vs. unearned, contested
credit, ambiguous advance) are surfaced to the scorer as an explicit one-tap decision — the system
never silently decides a scoring judgment. The v1 scope is designed to cover roughly 95% of plays in a
typical amateur/college game using the Retrosheet reduced grammar (a design target, not yet field-validated).

**Why I'm writing to this committee specifically:** my system's accuracy gates (SC-001: ≥90%
play-type accuracy; SC-002: ≥85% Reisner token accuracy) are not field-credible until I have
**independently hand-scored gold games from real amateur/college play**. I can build all the
software I want against MLB Retrosheet data, but the beachhead is serious scorers working
amateur/college games — and those games need their own ground truth.

**What I'm asking for:** I'm looking for 2–3 active official scorers willing to collaborate on
producing 2–3 gold games from real amateur or college play. The collaboration would involve:

1. **Narrate** a real game you've scored (20–40 minutes of audio narration, one play at a time)  
2. **Provide your Reisner hand-scoring** of that game (the ground truth)  
3. **Optionally produce the Retrosheet event file** (if you work in Retrosheet format) — or I can
   produce it independently and cross-validate against your Reisner scoring  
4. **One feedback session** on the app's play recognition and Reisner output (≤60 min)

In return I'll provide: credit in the app and documentation, early access to the app for your own
scoring, and compensation for your time (happy to discuss per your preference — honorarium,
charitable donation to a baseball organization of your choice, etc.).

This is a **parallel, non-blocking** collaboration — you'd be contributing to the eval ground
truth that makes the accuracy numbers credible, not blocking the build. Your scoring expertise
would make Diamond Ledger meaningfully better at the specific plays that separate good scorers
from great ones.

If you know committee members who might be interested, I'd also be grateful for a direct
introduction rather than a cold list post.

Thank you for the work this committee does. I hope Diamond Ledger can eventually make it easier
for serious scorers to contribute Retrosheet-quality records at levels below MLB.

Matt Wollschleger  
Diamond Ledger  
[contact info]

---

### Notes on this draft

- The SABR audience is knowledgeable and serious about scoring. Use the technical terms correctly
  (Reisner, Retrosheet, cwevent) — they'll notice errors.
- The "what I'm asking for" list is specific and bounded — 2–3 games, not open-ended.
- The ask for introduction (last paragraph) is the real goal at first contact — getting one warm
  connection to an active scorer is more valuable than a mass list post.
- **Timing**: send after the first gold game harness is committed (this PR). The credibility of
  "I've already built the harness" helps.
- **Follow-up cadence**: if no response after the initial post, follow up after 1 week; consider
  attending a SABR virtual committee meeting to make the ask in person.

---

## Track 1C — Local SABR chapter contacts

Beyond the national committee, local SABR chapters often include active scorers with
amateur/college connections. Chapters to consider:

| Chapter | City | Notes |
|---------|------|-------|
| Elysian Fields (Los Angeles) | Los Angeles, CA | Large chapter; LAN region aligns with gold game candidate |
| Casey At The Bat (New York) | New York, NY | Active chapter; NYN region aligns with gold game candidate |
| Deadball Era (national, remote) | Remote | Research-focused; may have scoring committee connections |

**Action**: check current chapter officers at https://sabr.org/chapters/ and send a version of
the Track 1B email adapted for the local context.

---

## What NOT to ask for

- Do NOT ask Retrosheet for their MLB data as gold-game source material — it has no audio narration
  and represents professional play, not the amateur beachhead.
- Do NOT promise a revenue share or equity — keep collaboration simple (honorarium / credit).
- Do NOT gate the gold game production on getting outside scorers — the primary path (project lead
  as scorer, self-sourced) is in our control.

---

## ADR-0006 distribution tripwire connection

Failing to assemble even 2–3 collaborators for gold games is a weak signal but worth noting. The
stronger tripwire is the **~20 serious-scorer demo cohort** — see `docs/outreach/demo-cohort-tracker.md`.

If by **2026-07-31**:
- No external scorer has agreed to co-produce a gold game, AND
- The demo cohort (20 scorers) cannot be assembled

then both signals together constitute the ADR-0006 "distribution/GTM red flag" and trigger an
explicit documented reassessment before scaling.

The SABR/Retrosheet relationships are parallel lead-time work — start them now, but do not block
the build on them.
