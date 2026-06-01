/* App — orchestrates the capture → read-verify → confirm/correct loop.
   State never advances until the scorer confirms (FR-007). Judgment plays are
   never auto-resolved (FR-010). Corrections replay from scratch and recompute
   downstream state visibly (FR-012), preserving the prior notation. */

const { useState, useEffect, useRef } = React;
const DL = window.DL;

function addLine(line, delta) {
  if (!delta) return;
  for (const side in delta) for (const k in delta[side]) line[side][k] += delta[side][k];
}

// Fold the confirmed plays (in canonical script order) into game state.
function replay(recorded) {
  const s = DL.clone(DL.initialState);
  let phase = 'top1';
  const ordered = [...recorded].sort((a, b) => a.index - b.index);
  for (const rec of ordered) {
    const p = DL.plays[rec.index];
    if (p.half === 'bot1' && s.battingSide === 'away') {
      s.battingSide = 'home'; s.outs = 0; s.bases = { 1: false, 2: false, 3: false }; s.dueSpot = 1;
    }
    s.outs = p.after.outs;
    s.bases = DL.clone(p.after.bases);
    s.dueSpot = p.after.dueSpot;
    addLine(s.line, p.after.line);
    addLine(s.line, rec.option && rec.option.line);
    phase = p.half === 'bot1' ? 'bot1' : (p.retire ? 'mid1' : 'top1');
  }
  s.inningHalf = phase;
  s.count = { b: 0, s: 0 };
  return s;
}

function App() {
  const [recorded, setRecorded] = useState([]);
  const [pending, setPending] = useState(null);     // { play, index, kind?, correcting? }
  const [talkState, setTalkState] = useState('idle');
  const [scriptIndex, setScriptIndex] = useState(0);
  const [variant, setVariant] = useState('V1');
  const [wozOpen, setWozOpen] = useState(false);
  const [log, setLog] = useState([]);
  const [taps, setTaps] = useState(0);
  const [flash, setFlash] = useState(false);
  const [correcting, setCorrecting] = useState(null); // recorded-array position being corrected
  const [events, setEvents] = useState([]); // facilitator observations (e.g. "Edit fielders" taps)
  const shownAt = useRef(0);
  const procTimer = useRef(null);

  // open facilitator via ?woz
  useEffect(() => {
    if (/[?&]woz/.test(window.location.search)) setWozOpen(true);
  }, []);

  const gs = replay(recorded);
  const uidRef = useRef(1);

  const logEvent = (label) => setEvents((e) => [...e, { label, at: Date.now() }]);

  const flashRecompute = () => { setFlash(true); setTimeout(() => setFlash(false), 900); };

  // --- present a card (solo talk or facilitator pick) ---
  const showPlay = (i) => {
    setCorrecting(null);
    setPending({ play: DL.plays[i], index: i });
    setScriptIndex(i);
    shownAt.current = Date.now();
  };

  const onTalkStart = () => setTalkState('listening');
  const onTalkEnd = () => {
    setTalkState('processing');
    if (procTimer.current) clearTimeout(procTimer.current);
    procTimer.current = setTimeout(() => {
      setTalkState('idle');
      if (scriptIndex < DL.plays.length) showPlay(scriptIndex);
    }, 720);
  };

  // --- commit a play into the book ---
  const commit = (rec) => {
    const isCorrection = correcting != null;
    let next;
    const existingPos = recorded.findIndex((r) => r.index === rec.index);
    if (existingPos >= 0) {
      next = recorded.map((r, k) => k === existingPos
        ? { ...rec, edited: true, prevNotation: r.notation, corrected: true }
        : r);
    } else {
      next = [...recorded, rec];
    }
    setRecorded(next);
    setPending(null);
    setCorrecting(null);
    setTalkState('idle');
    setScriptIndex(Math.max(scriptIndex, rec.index + 1));
    const secs = Math.max(0.4, (Date.now() - shownAt.current) / 1000);
    setLog((L) => [...L, { notation: rec.notation, secs, judgment: rec.judgment, corrected: isCorrection || existingPos >= 0 }]);
    setTaps((t) => t + 1);
    if (isCorrection || existingPos >= 0) flashRecompute();
  };

  const handleConfirmA = () => {
    const p = pending.play;
    commit({
      uid: uidRef.current++, index: pending.index, option: null,
      notation: p.notation, scored: !!p.scored, pending: false, judgment: false,
    });
  };

  const handleResolveB = (play, option, customNotation) => {
    commit({
      uid: uidRef.current++, index: pending.index, option,
      notation: customNotation || option.notation || play.notation,
      scored: !!play.scored, pending: !!option.pending, judgment: true,
    });
  };

  // dismiss a read-back without committing (re-record / clarify retry)
  const dismiss = () => {
    setPending(null);
    setCorrecting(null);
    setTalkState('idle');
    setTaps((t) => t + 1);
  };

  // --- corrections via strip chips ---
  const orderedRec = [...recorded].sort((a, b) => a.index - b.index);
  const openCorrection = (recArrayPos) => {
    const rec = orderedRec[recArrayPos];
    const realPos = recorded.findIndex((r) => r.uid === rec.uid);
    setCorrecting(realPos);
    setPending({ play: DL.plays[rec.index], index: rec.index, correcting: true });
    shownAt.current = Date.now();
    setWozOpen(false);
  };

  const triggerAmbiguous = () => {
    setCorrecting(null);
    setPending({ kind: 'clarify', play: DL.ambiguous });
    setWozOpen(false);
    shownAt.current = Date.now();
  };

  const reset = () => {
    setRecorded([]); setPending(null); setTalkState('idle'); setScriptIndex(0);
    setLog([]); setTaps(0); setCorrecting(null); setWozOpen(false); setEvents([]);
  };

  // --- derived display ---
  const showTop = gs.inningHalf === 'top1' || gs.inningHalf === 'mid1';
  const halfLabel = showTop ? 'Top 1st' : 'Bottom 1st';
  const teamLabel = showTop ? 'Oakmont' : 'Riverside';
  const stripChips = orderedRec
    .map((r, pos) => ({ ...r, recPos: pos, half: DL.plays[r.index].half }))
    .filter((c) => c.half === (showTop ? 'top1' : 'bot1'));

  const blockTalk = !!pending;

  // status bar clock
  const clock = '7:24';

  return (
    <div id="stage">
      <div className="device">
        <div className="screen">
          <div className="statusbar">
            <span className="mono">{clock}</span>
            <span className="sb-icons">
              <svg width="17" height="11" viewBox="0 0 17 11" fill="currentColor"><rect x="0" y="7" width="3" height="4" rx="1"/><rect x="4.5" y="5" width="3" height="6" rx="1"/><rect x="9" y="2.5" width="3" height="8.5" rx="1"/><rect x="13.5" y="0" width="3" height="11" rx="1"/></svg>
              <svg width="16" height="11" viewBox="0 0 16 11" fill="none" stroke="currentColor" strokeWidth="1.2"><path d="M1 4.5a10 10 0 0 1 14 0M3.5 7a6.5 6.5 0 0 1 9 0M8 9.4l.01-.01" strokeLinecap="round"/></svg>
              <svg width="24" height="11" viewBox="0 0 24 11" fill="none"><rect x="0.5" y="0.5" width="20" height="10" rx="2.5" stroke="currentColor" opacity="0.5"/><rect x="2" y="2" width="15" height="7" rx="1" fill="currentColor"/><rect x="21.5" y="3.5" width="1.5" height="4" rx="0.75" fill="currentColor" opacity="0.5"/></svg>
            </span>
          </div>

          <Hud state={gs} onLongPress={() => setWozOpen(true)} />

          <div className={`book ${flash ? 'recompute' : ''}`}>
            <ScorebookStrip
              chips={stripChips}
              halfLabel={halfLabel}
              teamLabel={teamLabel}
              onChipClick={(recPos) => openCorrection(recPos)}
            />

            <div className="stage-card">
              {!pending && gs.inningHalf === 'mid1' && (
                <div className="idle">
                  <svg className="eye" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M4 10.5l4 4 8-9"/></svg>
                  <div className="l1">Middle of the 1st</div>
                  <div className="l2">Side retired. Riverside up next — hold to talk after the first play.</div>
                </div>
              )}
              {!pending && gs.inningHalf !== 'mid1' && (
                <div className="idle">
                  <svg className="eye" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/></svg>
                  <div className="l1">{recorded.length === 0 ? 'Watch the play.' : 'Keep your eyes up.'}</div>
                  <div className="l2">{scriptIndex >= DL.plays.length
                    ? 'End of the scripted half. Open the facilitator drawer to replay or reset.'
                    : 'After it happens, hold the button and say what you saw.'}</div>
                </div>
              )}

              {pending && pending.kind === 'clarify' && (
                <ClarifyCard data={pending.play} onRetry={dismiss} onManual={dismiss} />
              )}
              {pending && !pending.kind && pending.play.card === 'A' && (
                <CardA play={pending.play} correcting={!!pending.correcting}
                  onConfirm={handleConfirmA} onCorrect={dismiss} />
              )}
              {pending && !pending.kind && pending.play.card === 'B' && (
                <CardB play={pending.play} variant={variant} correcting={!!pending.correcting}
                  onResolve={handleResolveB} onCorrect={dismiss} onLog={logEvent} />
              )}
            </div>
          </div>

          <TalkButton talkState={talkState} disabled={blockTalk}
            onStart={onTalkStart} onEnd={onTalkEnd} />

          {!wozOpen && (
            <button className="woz-handle" onClick={() => setWozOpen(true)} aria-label="Facilitator">
              <span className="grip" />
            </button>
          )}
          {wozOpen && (
            <WozDrawer
              plays={DL.plays}
              currentIndex={pending ? pending.index : scriptIndex}
              doneIds={recorded.map((r) => DL.plays[r.index].id)}
              variant={variant}
              log={log}
              events={events}
              totalTaps={taps}
              onSetVariant={setVariant}
              onPlay={(i) => { showPlay(i); setWozOpen(false); }}
              onAmbiguous={triggerAmbiguous}
              onReset={reset}
              onClose={() => setWozOpen(false)}
            />
          )}
        </div>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
