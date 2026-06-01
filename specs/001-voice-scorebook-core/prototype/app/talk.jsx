/* Talk dock + scorebook strip.
   Exports: ScorebookStrip, TalkButton */

function ScorebookStrip({ chips, halfLabel, teamLabel, onChipClick }) {
  return (
    <div className="strip">
      <div className="strip-head">
        <span>Scorebook · {halfLabel} · {teamLabel}</span>
        <span className="proof">proof box balances</span>
      </div>
      <div className="chips">
        {chips.length === 0 && <span className="chip empty">No plays yet this half.</span>}
        {chips.map((c, i) => {
          const cls = c.pending ? 'pending' : c.scored ? 'scored' : '';
          return (
            <button key={c.uid} className={`chip ${cls}`} onClick={() => onChipClick && onChipClick(c.recPos)} title="Tap to correct">
              <span className="seq mono">{i + 1}</span>
              <span className="mono">{c.notation}</span>
              {c.scored && !c.pending && <span className="dotr" />}
              {c.pending && <span className="pend">pending</span>}
              {c.edited && <span style={{ color: 'var(--ink-4)', fontSize: '11px' }} title={`was ${c.prevNotation}`}>{'\u00B7 edited'}</span>}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function TalkButton({ talkState, disabled, onStart, onEnd }) {
  const hint = disabled
    ? 'Confirm the play above to continue'
    : talkState === 'listening' ? 'Listening… release when the play is done'
    : talkState === 'processing' ? 'Reading it back…'
    : 'Hold to talk — eyes on the field';

  const down = (e) => { e.preventDefault(); if (!disabled && talkState === 'idle') onStart(); };
  const up = (e) => { e.preventDefault(); if (talkState === 'listening') onEnd(); };

  return (
    <div className="dock">
      <div className="talkhint" style={talkState === 'listening' ? { color: 'var(--teal)' } : null}>{hint}</div>
      <button
        className={`talk ${talkState}`}
        disabled={disabled}
        onPointerDown={down}
        onPointerUp={up}
        onPointerLeave={up}
        onContextMenu={(e) => e.preventDefault()}
        aria-label="Hold to talk"
      >
        <span className="ring" />
        {talkState === 'idle' && (
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
            <rect x="9" y="3" width="6" height="11" rx="3" />
            <path d="M5 11a7 7 0 0 0 14 0" />
            <path d="M12 18v3" />
          </svg>
        )}
        {talkState === 'listening' && (
          <span className="eq"><i /><i /><i /><i /><i /></span>
        )}
        {talkState === 'processing' && <span className="spinner" />}
      </button>
      <div className="homebar" />
    </div>
  );
}

Object.assign(window, { ScorebookStrip, TalkButton });
