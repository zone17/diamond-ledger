/* Cards — the result surface.
   CardA  : deterministic read-verify (the ~85%) — calm, one-tap confirm.
   CardB  : scorer-judgment (the ~15%) — three postures V1/V2/V3.
   Clarify: low-confidence re-prompt (never a guess).
   Exports to window. */

const { useState } = React;

/* ---------- shared bits ---------- */
function Kicker({ label, tone }) {
  return (
    <div className="card-kicker" style={tone ? { color: tone } : null}>
      <span className="tk" style={tone ? { background: tone } : null} />
      {label}
    </div>
  );
}

function Recommendation({ rec }) {
  return (
    <div className="rec">
      <svg className="ricon" viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
        <path d="M10 2.5a5 5 0 0 0-3 9v2h6v-2a5 5 0 0 0-3-9Z" />
        <path d="M8 16.5h4" />
      </svg>
      <div className="rtxt">
        <span className="sug">Engine suggests — a recommendation, not a decision</span>
        <b>{rec.call}.</b> {rec.why}
      </div>
    </div>
  );
}

/* ---------- Card A — deterministic ---------- */
function CardA({ play, chosen, correcting, onConfirm, onCorrect }) {
  // `chosen` lets a resolved judgment reuse the read-back styling (unused in current flow)
  return (
    <div className={`card ${correcting ? 'enterA' : 'enterA'}`}>
      <Kicker label={correcting ? 'Correcting entry' : 'Recorded'} />
      <div className="restate">{play.restate}</div>
      <div className="notation">
        <span className="nlbl">Notation</span>
        <span className="tok mono">{play.notation}</span>
      </div>
      {play.delta && (play.delta.retire ? (
        <div className="delta retire">
          <svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="var(--teal)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 10.5l4 4 8-9" /></svg>
          <span><b>3rd out</b> — side retired</span>
        </div>
      ) : (
        <div className="delta">
          <span className="from">{play.delta.from}</span>
          <span className="arrow">{'\u2192'}</span>
          <span className="to">{play.delta.to}</span>
        </div>
      ))}
      <div className="card-actions">
        <button className="btn btn-primary" onClick={onConfirm}>
          <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 10.5l4 4 8-9" /></svg>
          {correcting ? 'Save correction' : 'Confirm'}
        </button>
        <button className="btn btn-ghost" onClick={onCorrect}>{correcting ? 'Cancel' : 'Re-record'}</button>
      </div>
    </div>
  );
}

/* ---------- fielder edit (h4 contested credit) ---------- */
function FielderEdit({ onPick, onCancel }) {
  const [n, setN] = useState(null);
  return (
    <div style={{ marginTop: '14px' }}>
      <div style={{ fontSize: '12px', color: 'var(--ink-3)', marginBottom: '9px' }}>
        Who threw home for the putout?
      </div>
      <div style={{ display: 'flex', gap: '7px', flexWrap: 'wrap' }}>
        {window.DL.fielders.map((f) => (
          <button
            key={f.n}
            onClick={() => setN(f.n)}
            className="choice"
            style={{
              flex: '0 0 auto', minHeight: '46px', padding: '0 12px',
              borderColor: n === f.n ? 'var(--amber)' : 'var(--line-2)',
              background: n === f.n ? 'var(--amber-tint)' : 'var(--panel-hi)',
            }}
          >
            <span className="ctitle mono" style={{ fontSize: '15px' }}>{f.n}</span>
            <span className="csub">{f.label}</span>
          </button>
        ))}
      </div>
      <div className="card-actions" style={{ marginTop: '12px' }}>
        <button className="btn btn-primary amber" disabled={n == null} style={n == null ? { opacity: 0.45 } : null}
          onClick={() => n != null && onPick(`FC${n}-2`)}>
          Credit {n != null ? `${n}\u20132` : 'putout'}
        </button>
        <button className="btn btn-ghost" onClick={onCancel}>Back</button>
      </div>
    </div>
  );
}

/* ---------- Card B — scorer judgment ---------- */
function CardB({ play, variant, correcting, onResolve, onCorrect }) {
  const main = play.options.filter((o) => !o.pending);
  const pending = play.options.find((o) => o.pending);
  const recKey = (play.options.find((o) => o.recommended) || {}).key;
  const [armed, setArmed] = useState(recKey || (play.options[0] && play.options[0].key));
  const [editing, setEditing] = useState(false);

  const commit = (opt, customNotation) => {
    if (opt.edit && !customNotation) { setEditing(true); return; }
    onResolve(play, opt, customNotation);
  };

  if (editing) {
    const editOpt = play.options.find((o) => o.edit);
    return (
      <div className={`card judgment enterB`}>
        <div className="yourcall"><span className="pulse" />Your call · confirm fielders</div>
        <div className="question">{play.question}</div>
        <FielderEdit onPick={(notation) => commit(editOpt, notation)} onCancel={() => setEditing(false)} />
      </div>
    );
  }

  const callTag = (opt) => opt.recommended ? <span className="tag">Suggested</span> : null;

  /* ----- V3 glance: giant stacked targets, minimal text ----- */
  if (variant === 'V3') {
    return (
      <div className="card judgment glance3 enterB">
        <div className="yourcall"><span className="pulse" />Your call</div>
        <div className="question">{play.question}</div>
        <div className="why3">Engine leans <b>{play.recommendation.call}</b>.</div>
        <div className="gbtns">
          {main.map((o) => (
            <button key={o.key} className={`gbtn ${o.recommended ? 'suggested' : ''}`} onClick={() => commit(o)}>
              <span className="gt">{o.title}</span>
              <span className="gmeta">
                {o.recommended && <span className="gtag">Suggested</span>}
                <span className="gn mono">{o.sub}</span>
              </span>
            </button>
          ))}
          {pending && (
            <button className={`gbtn ${pending.recommended ? 'suggested' : ''}`} onClick={() => commit(pending)}
              style={{ borderStyle: 'dashed' }}>
              <span className="gt" style={{ fontSize: '24px', color: 'var(--amber)' }}>{pending.title}</span>
              <span className="gmeta">
                {pending.recommended && <span className="gtag">Suggested</span>}
                <span className="gn">{pending.sub}</span>
              </span>
            </button>
          )}
        </div>
      </div>
    );
  }

  /* ----- V2 inline two-tap toggle: prominent default, deliberate confirm ----- */
  if (variant === 'V2') {
    const armedOpt = play.options.find((o) => o.key === armed) || play.options[0];
    return (
      <div className="card judgment enterB">
        <div className="yourcall"><span className="pulse" />Your call</div>
        <div className="question">{play.question}</div>
        <Recommendation rec={play.recommendation} />
        <div className="seg">
          {play.options.map((o) => (
            <button key={o.key} className={`opt ${armed === o.key ? 'armed' : ''}`} onClick={() => setArmed(o.key)}>
              <span className="ot">{o.title.length > 12 ? o.title.split(' ')[0] : o.title}</span>
              <span className="os">{o.sub}</span>
            </button>
          ))}
        </div>
        <div className="seg-hint">
          {armedOpt.recommended
            ? <span><b>Suggested</b> call armed — tap to lock it in, or pick another above.</span>
            : <span>Armed: <b>{armedOpt.title}</b> — a deliberate tap commits it.</span>}
        </div>
        <div className="card-actions" style={{ marginTop: '12px' }}>
          <button className="btn btn-primary amber btn-block" onClick={() => commit(armedOpt)}>
            Lock in — {armedOpt.title}
          </button>
        </div>
      </div>
    );
  }

  /* ----- V1 decision sheet (default): scrim + bottom sheet posture ----- */
  return (
    <React.Fragment>
      <div className="woz-scrim" style={{ zIndex: 9, background: 'oklch(0% 0 0 / 0.42)' }} onClick={(e) => e.stopPropagation()} />
      <div className="card judgment enterB" style={{ zIndex: 10, bottom: '12px' }}>
        <div className="yourcall"><span className="pulse" />Your call</div>
        <div className="question">{play.question}</div>
        <Recommendation rec={play.recommendation} />
        <div className="choices">
          {main.map((o) => (
            <button key={o.key} className={`choice ${o.recommended ? 'suggested' : ''}`} onClick={() => commit(o)}>
              {callTag(o)}
              <span className="ctitle">{o.title.length > 14 ? o.title : o.title}</span>
              <span className="csub mono">{o.sub}</span>
            </button>
          ))}
        </div>
        {pending && (
          <button className="leavepending" onClick={() => commit(pending)}>
            <svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="10" cy="10" r="7" /><path d="M10 6v4l2.5 1.5" /></svg>
            {pending.title}{pending.recommended ? ' · suggested' : ''}
          </button>
        )}
      </div>
    </React.Fragment>
  );
}

/* ---------- Clarify — low confidence, never a guess ---------- */
function ClarifyCard({ data, onRetry, onManual }) {
  return (
    <div className="card clarify enterA">
      <Kicker label="Didn't catch that" tone="var(--ink-3)" />
      <div className="question">{data.prompt}</div>
      <div className="csubtxt">{data.sub}</div>
      <div className="card-actions">
        <button className="btn btn-primary" onClick={onRetry}>
          <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M15 7a6 6 0 1 0 1.5 4" /><path d="M15 3v4h-4" /></svg>
          Say it again
        </button>
        <button className="btn btn-ghost" onClick={onManual}>Enter by hand</button>
      </div>
    </div>
  );
}

Object.assign(window, { CardA, CardB, ClarifyCard, FielderEdit, Kicker, Recommendation });
