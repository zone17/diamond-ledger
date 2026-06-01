/* Wizard-of-Oz facilitator drawer — hidden from the test subject.
   Lists the scripted plays, switches the Card-B variant, triggers the
   ambiguous re-prompt, and logs taps + per-play resolve time (A5 metrics).
   Exports: WozDrawer */

function median(arr) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function WozDrawer({ plays, currentIndex, doneIds, variant, log, events, totalTaps, onSetVariant, onPlay, onAmbiguous, onReset, onClose }) {
  const variants = [
    { k: 'V1', n: 'V1 · Sheet', d: 'Bottom decision sheet' },
    { k: 'V2', n: 'V2 · Inline', d: 'Two-tap armed toggle' },
    { k: 'V3', n: 'V3 · Glance', d: 'Giant ≤5s targets' },
  ];
  const groups = [
    { label: 'Top 1st — Oakmont bats', half: 'top1' },
    { label: 'Bottom 1st — Riverside bats', half: 'bot1' },
  ];
  const med = median(log.map((l) => l.secs));
  const jMed = median(log.filter((l) => l.judgment).map((l) => l.secs));

  return (
    <React.Fragment>
      <div className="woz-scrim" onClick={onClose} />
      <div className="woz" role="dialog" aria-label="Facilitator control">
        <div className="woz-grip" />
        <div className="woz-head">
          <div className="t">
            <h3>Facilitator</h3>
            <button className="x" onClick={onClose} aria-label="Close">
              <svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M5 5l10 10M15 5L5 15" /></svg>
            </button>
          </div>
          <div className="sub">Wizard of Oz · hidden from the scorer. Tap the play they just spoke.</div>
        </div>

        <div className="woz-body">
          <div className="woz-sec">Judgment card — variant under test</div>
          <div className="variant-switch">
            {variants.map((v) => (
              <button key={v.k} className={`vb ${variant === v.k ? 'on' : ''}`} onClick={() => onSetVariant(v.k)}>
                <div className="vn">{v.n}</div>
                <div className="vd">{v.d}</div>
              </button>
            ))}
          </div>

          {groups.map((g) => (
            <React.Fragment key={g.half}>
              <div className="woz-sec">{g.label}</div>
              <div className="play-list">
                {plays.map((p, i) => p.half === g.half ? (
                  <button
                    key={p.id}
                    className={`play-row ${p.kind === 'judgment' ? 'j' : ''} ${doneIds.includes(p.id) ? 'done' : ''} ${i === currentIndex ? 'cur' : ''}`}
                    onClick={() => onPlay(i)}
                  >
                    <span className="ptok mono">{p.notation}</span>
                    <span className="pmid">
                      <span className="psaid">"{p.said}"</span>
                      <span className="pmeta">{p.restate || p.question}</span>
                    </span>
                    <span className={`pkind ${p.kind === 'judgment' ? 'jud' : 'det'}`}>{p.kind === 'judgment' ? 'Call' : 'Auto'}</span>
                  </button>
                ) : null)}
              </div>
            </React.Fragment>
          ))}

          <div className="woz-sec">Couldn't parse it</div>
          <button className="amb-btn" onClick={onAmbiguous}>
            <svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M7.5 7.5a2.5 2.5 0 1 1 3.4 2.3c-.6.3-.9.7-.9 1.4v.3" /><path d="M10 15h.01" /></svg>
            Trigger "didn't catch that" — clarify, never guess
          </button>

          <div className="woz-sec">Session log · A5</div>
          <div className="woz-log">
            <div className="lhead">
              <span>Taps logged <b>{totalTaps}</b></span>
              <span>Median resolve <b>{med != null ? med.toFixed(1) + 's' : '—'}</b></span>
            </div>
            {log.length === 0 && <div className="lempty">No plays recorded yet.</div>}
            {log.slice(-6).map((l, i) => (
              <div className="lrow" key={i}>
                <span><span className="mono">{l.notation}</span>{l.judgment ? ' · call' : ''}{l.corrected ? ' · corrected' : ''}</span>
                <span className={`lt ${l.secs > (l.judgment ? 5 : 3) ? 'slow' : ''} mono`}>{l.secs.toFixed(1)}s</span>
              </div>
            ))}
            {jMed != null && (
              <div className="lrow" style={{ borderTopColor: 'var(--line-2)' }}>
                <span style={{ color: 'var(--ink-3)' }}>judgment median</span>
                <span className={`lt ${jMed > 5 ? 'slow' : ''} mono`}>{jMed.toFixed(1)}s</span>
              </div>
            )}
          </div>

          {events && events.length > 0 && (
            <React.Fragment>
              <div className="woz-sec">Observations · design the real editor from these</div>
              <div className="woz-log">
                {events.slice(-6).map((e, i) => (
                  <div className="lrow" key={i} style={i === 0 ? { borderTop: 'none' } : null}>
                    <span style={{ color: 'var(--amber)' }}>{e.label}</span>
                  </div>
                ))}
              </div>
            </React.Fragment>
          )}

          <button className="woz-reset" onClick={onReset}>Reset session</button>
        </div>
      </div>
    </React.Fragment>
  );
}

Object.assign(window, { WozDrawer });
