# Discovery — Opportunity Map

*Diamond Ledger · selecting & justifying the opportunity in the bet · 2026-06-01*

Opportunity-solution tree (Torres) + ODI Opportunity Score
`Opportunity = Importance + max(Importance − Satisfaction, 0)` (1–10 each; **≥15 highly
attractive/under-served, 10–15 attractive, <10 over-served**). Effort is deliberately excluded.
Importance/Satisfaction are grounded in the research synthesis, **rated for the serious/official
scorekeeper beachhead** unless noted (the rec parent's ratings differ and are called out).

## Desired outcome (root)

**Maximize complete, accurate, exportable scorebooks produced per active scorer per season.**
(An outcome — completeness, accuracy, portability, and repeat use — not a feature.)

## Opportunity space (problems; each admits multiple solutions)

```
ROOT: complete, accurate, exportable scorebooks per scorer per season
├─ O1  "I can't keep the book and watch the game at once"        (attention)
├─ O2  "Scoring is too hard to learn / notation is arcane"        (skill barrier)
├─ O3  "My book isn't accurate enough to be trusted / official"   (accuracy & officialness)
├─ O4  "My data is trapped and not industry-standard"             (portability / Retrosheet)
├─ O5  "Scoring takes too long / too many taps"                   (speed)
└─ O6  "I want absent family to follow the game"                  (sharing / streaming)
```

Each passes the litmus test (multiple possible solutions), e.g. O1 → voice / computer-vision /
simplified tap / outsourced human scorer / record-and-score-later.

## Scored opportunities

| Opp | Importance | Satisfaction | **Score** | Read |
|---|---|---|---|---|
| **O3 Accuracy & officialness** | 9 | 3 | **15** | Highly attractive / under-served |
| **O4 Portability / Retrosheet** | 8 | 2 | **14** | Attractive; *no incumbent serves it* |
| O1 Attention | 8 | 3 | **13** | Attractive — but lead pain is **low-WTP** for rec parent (Imp 8 / Sat 3 = 13 there too, yet GC-owned + free) |
| O2 Skill barrier | 8 | 3 | **13** | Attractive; voice removes notation entirely |
| O5 Speed / fewer taps | 6 | 5 | **7** | Over-served — GC already optimized taps |
| O6 Sharing / streaming | 8 | 7 | **9** | Over-served by GameChanger; **do not enter** |

**Sizing / market / fit overlay (Torres's other three factors):**
- O3+O4 are smaller in raw headcount than O1, but **monetizable** (serious scorers already pay)
  and **defensible** (GC deliberately closed; iScore hasn't shipped Retrosheet in 8 years).
- O1/O2 are the largest headcount but **lowest WTP** and sit on the incumbent's distribution moat.
- O6 is a trap: the incumbent's core strength. The PR/FAQ already excludes it — correct.

## Solution space for the target opportunity (O3 + O4, attention-free)

Compare-and-contrast, not whether-or-not. The target opportunity is *accurate, exportable scoring
without sacrificing attention* — solutions:

| Solution | How it scores the game | Strength | Weakness |
|---|---|---|---|
| **S1 Voice → deterministic rules engine → Retrosheet** *(Diamond Ledger)* | Speak the play; engine applies rules, renders notation, exports Retrosheet | Attention-free, official-grade, open export, feasible now | ~15% judgment plays need confirm; ballpark ASR risk |
| S2 Computer-vision auto-scoring *(Pocket Blue path)* | Camera watches & infers | Zero human input | Mount/setup, can't judge hit/error, no full book, hardware-bound |
| S3 Faster tap UI *(Rizzler / GC redesign)* | Fewer-tap manual entry | Familiar, deterministic | Still eyes-on-screen — doesn't solve O1 |
| S4 Outsourced human scorer / score-from-video later | A person scores live or post-game | Accurate | Costly, not real-time, doesn't scale to every team |

S1 is the only solution that hits O1 **and** O3 **and** O4 simultaneously, and "why now" makes it
newly feasible. S2 is the nearest credible rival and validates the problem; S3 is the incumbents.

## Verdict

**The PR/FAQ's *product* (voice → official scorebook) is the right solution — but its *beachhead*
is on the wrong opportunity.** It leads with O1 (attention) aimed at the tee-ball parent, which is
the lowest-WTP, most incumbent-dominated cell. The highest-scoring, monetizable, defensible
opportunities are **O3 (15) + O4 (14)** — accuracy + Retrosheet portability — owned by the
**serious/official scorekeeper** for whom O1 and O2 *also* score 13. 

**→ REFINE the bet:** keep the product and the long-term parent TAM, but make the *entry wedge*
the underserved paying scorer (travel/HS/college + Retrosheet archivist), where voice + accuracy +
open export combine and where GameChanger structurally will not follow. The rec parent becomes
top-of-funnel expansion *after* the beachhead proves the engine, not the launch customer.
