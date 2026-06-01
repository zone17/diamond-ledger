/* Diamond Ledger — Wizard-of-Oz stimulus.
   Scripted half-inning from specs/.../prototype/scripted-plays.json (verbatim
   spoken examples + notation), plus the resulting game-state snapshot each play
   produces. No fabricated stats — only structural base/out/line state that the
   scripted plays imply. Teams: Oakmont (away) @ Riverside (home), 14U travel scrimmage.  */
(function () {
  // base/out state helpers
  const B = (a, b, c) => ({ 1: !!a, 2: !!b, 3: !!c });
  const empty = () => B(0, 0, 0);

  const initialState = {
    inningHalf: 'top1',        // top1 | mid1 | bot1
    battingSide: 'away',
    outs: 0,
    bases: empty(),
    count: { b: 0, s: 0 },
    line: { away: { r: 0, h: 0, e: 0 }, home: { r: 0, h: 0, e: 0 } },
    dueSpot: 1,
  };

  // Each play carries the state it RESULTS IN (`after`) so the HUD can fold the
  // confirmed sequence. Judgment plays carry branch effects (line/notation) that
  // depend on the scorer's call but never on base/out state.
  const plays = [
    // ---------------- TOP 1 — Oakmont batting, Riverside fielding ----------------
    {
      id: 'v1', half: 'top1', kind: 'det', card: 'A',
      said: 'ground ball to short, threw him out at first',
      restate: 'Ground out, short to first.', notation: '6-3',
      delta: { from: '0 out', to: '1 out' },
      after: { outs: 1, bases: empty(), dueSpot: 2 },
    },
    {
      id: 'v2', half: 'top1', kind: 'det', card: 'A',
      said: 'swinging strikeout',
      restate: 'Strikeout swinging.', notation: 'K',
      delta: { from: '1 out', to: '2 outs' },
      after: { outs: 2, bases: empty(), dueSpot: 3 },
    },
    {
      id: 'v3', half: 'top1', kind: 'det', card: 'A',
      said: 'line drive single to left',
      restate: 'Single to left.', notation: 'S7',
      delta: { from: 'bases empty', to: 'runner on 1st' },
      after: { outs: 2, bases: B(1, 0, 0), dueSpot: 4, line: { away: { h: +1 } } },
    },
    {
      id: 'v4', half: 'top1', kind: 'judgment', card: 'B', judgment: 'hit_vs_error',
      said: 'grounder to short, he bobbled it — runner safe at first',
      question: 'Hit or error?',
      recommendation: { call: 'Error', why: 'Routine grounder misplayed by the shortstop — E6.' },
      delta: { from: 'runner on 1st', to: 'runners on 1st & 2nd' },
      after: { outs: 2, bases: B(1, 1, 0), dueSpot: 5 },
      options: [
        { key: 'hit', title: 'Hit', sub: 'S6', notation: 'S6', line: { away: { h: +1 } } },
        { key: 'error', title: 'Error', sub: 'E6', notation: 'E6', recommended: true, line: { home: { e: +1 } } },
      ],
    },
    {
      id: 'v5', half: 'top1', kind: 'det', card: 'A',
      said: 'fly ball to center, caught',
      restate: 'Flyout to center.', notation: '8', retire: true,
      delta: { retire: true, text: '3rd out — side retired' },
      after: { outs: 3, bases: B(1, 1, 0), dueSpot: 5 },
    },

    // ---------------- BOT 1 — Riverside batting, Oakmont fielding ----------------
    {
      id: 'h1', half: 'bot1', kind: 'det', card: 'A',
      said: 'walk',
      restate: 'Walk.', notation: 'W',
      delta: { from: 'bases empty', to: 'runner on 1st' },
      after: { outs: 0, bases: B(1, 0, 0), dueSpot: 2 },
    },
    {
      id: 'h2', half: 'bot1', kind: 'det', card: 'A',
      said: 'double down the line, runner to third',
      restate: 'Double — runner to 3rd.', notation: 'D7.1-3',
      delta: { from: 'runner on 1st', to: 'runners on 2nd & 3rd' },
      after: { outs: 0, bases: B(0, 1, 1), dueSpot: 3, line: { home: { h: +1 } } },
    },
    {
      id: 'h3', half: 'bot1', kind: 'judgment', card: 'B', judgment: 'earned_vs_unearned',
      said: 'throwing error by the third baseman — a run scores',
      question: 'That run — earned or unearned?',
      recommendation: {
        call: 'Leave pending',
        why: "A run scored in an inning with an error — earned/unearned can't be settled until the inning ends. Rule 9.16 is deferred.",
      },
      delta: { from: 'runners on 2nd & 3rd', to: 'run scores · runners on 1st & 3rd' },
      // run scores; runner 2nd→3rd; batter reaches on error → 1st. Oakmont charged the error.
      after: { outs: 0, bases: B(1, 0, 1), dueSpot: 4, line: { home: { r: +1 }, away: { e: +1 } } },
      notation: 'E5.3-H', scored: true,
      options: [
        { key: 'earned', title: 'Earned', sub: 'ER' },
        { key: 'unearned', title: 'Unearned', sub: 'U' },
        { key: 'pending', title: 'Leave pending', sub: 'decide later', recommended: true, pending: true },
      ],
    },
    {
      id: 'h4', half: 'bot1', kind: 'judgment', card: 'B', judgment: 'contested_credit',
      said: "fielder's choice — they got the lead runner at home",
      question: "Who's credited? Confirm the play.",
      recommendation: {
        call: 'FC, out at home',
        why: "Fielder's choice; which fielder is charged the putout depends on who covered. Confirm before the book commits it.",
      },
      delta: { from: 'runners on 1st & 3rd', to: 'out at home · runners on 1st & 2nd' },
      after: { outs: 1, bases: B(1, 1, 0), dueSpot: 5 },
      notation: 'FC2',
      options: [
        { key: 'confirm', title: 'Confirm: 2 unassisted', sub: 'FC2', notation: 'FC2', recommended: true },
        { key: 'edit', title: 'Edit fielders', sub: 'pick the putout', edit: true },
      ],
    },
  ];

  const ambiguous = {
    id: 'amb1', card: 'clarify',
    prompt: "Didn't catch that.",
    sub: 'Say the play again, or tap to enter it by hand. The book won\u2019t guess.',
  };

  // fielder labels for the h4 "edit fielders" picker (Reisner position numbers)
  const fielders = [
    { n: 2, label: 'C' }, { n: 3, label: '1B' }, { n: 4, label: '2B' },
    { n: 5, label: '3B' }, { n: 6, label: 'SS' }, { n: 1, label: 'P' },
  ];

  window.DL = { initialState, plays, ambiguous, fielders, clone: (o) => JSON.parse(JSON.stringify(o)) };
})();
