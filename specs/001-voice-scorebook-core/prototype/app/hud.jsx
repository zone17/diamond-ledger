/* HUD — the glanceable game-state band. Readable in under a second.
   Exports: Hud, Diamond  (to window) */

function Diamond({ bases }) {
  // home bottom, 1B right, 2B top, 3B left
  const pos = { '2': [42, 12], '1': [72, 42], '3': [12, 42] };
  const home = [42, 72];
  const diamondPts = (cx, cy, s) => `${cx},${cy - s} ${cx + s},${cy} ${cx},${cy + s} ${cx - s},${cy}`;
  const baseEl = (key) => {
    const [cx, cy] = pos[key];
    const on = bases[key];
    return (
      <polygon
        key={key}
        points={diamondPts(cx, cy, 11)}
        fill={on ? 'var(--chalk)' : 'transparent'}
        stroke={on ? 'var(--chalk)' : 'var(--ink-4)'}
        strokeWidth="1.6"
        style={{ transition: 'fill .25s var(--ease), stroke .25s var(--ease)' }}
      />
    );
  };
  return (
    <div className="diamond-wrap" aria-label="bases">
      <svg viewBox="0 0 84 84" width="84" height="84">
        {/* basepaths */}
        <polygon
          points={`${42},${22} ${62},${42} ${42},${62} ${22},${42}`}
          fill="none" stroke="var(--line-2)" strokeWidth="1.4"
        />
        {baseEl('2')}
        {baseEl('1')}
        {baseEl('3')}
        {/* home plate — pentagon, never a runner slot */}
        <polygon
          points={`${home[0] - 8},${home[1] - 7} ${home[0] + 8},${home[1] - 7} ${home[0] + 8},${home[1]} ${home[0]},${home[1] + 8} ${home[0] - 8},${home[1]}`}
          fill="none" stroke="var(--ink-4)" strokeWidth="1.6"
        />
      </svg>
    </div>
  );
}

function LineScore({ state }) {
  const { line, battingSide, inningHalf } = state;
  const isTop = inningHalf.startsWith('top') || inningHalf.startsWith('mid');
  const teamRow = (key, name) => {
    const active = battingSide === key && !inningHalf.startsWith('mid');
    const bot = key === 'home';
    const l = line[key];
    return (
      <div className={`team-row ${active ? 'is-active' : ''}`} style={{ display: 'contents' }}>
        <div className={`team ${active ? 'active' : ''} ${bot ? 'bot' : ''}`}>
          <span className="bat" />
          <span>{name}</span>
        </div>
        <div className="v r mono">{l.r}</div>
        <div className="v mono">{l.h}</div>
        <div className="v mono">{l.e}</div>
      </div>
    );
  };
  return (
    <div className="linescore">
      <div className="ls-head" />
      <div className="ls-head r">R</div>
      <div className="ls-head">H</div>
      <div className="ls-head">E</div>
      {teamRow('away', 'Oakmont')}
      {teamRow('home', 'Riverside')}
    </div>
  );
}

function Hud({ state, onLongPress }) {
  const { inningHalf, outs, bases, count, dueSpot } = state;
  const isTop = inningHalf.startsWith('top');
  const isMid = inningHalf.startsWith('mid');
  const inningNum = 1;

  // long-press to open facilitator drawer
  const timer = React.useRef(null);
  const start = () => { timer.current = setTimeout(() => onLongPress && onLongPress(), 600); };
  const cancel = () => { if (timer.current) clearTimeout(timer.current); };

  const dots = [0, 1, 2].map((i) => <span key={i} className={`dot ${i < outs ? 'on' : ''}`} />);

  return (
    <div
      className="hud"
      onPointerDown={start}
      onPointerUp={cancel}
      onPointerLeave={cancel}
      onContextMenu={(e) => e.preventDefault()}
    >
      <div className="hud-top">
        <div className="brand">
          <span className="mark">
            <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
              <polygon points="12,3 21,12 12,21 3,12" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinejoin="round" />
            </svg>
          </span>
          <span className="wm">Diamond <em>Ledger</em></span>
        </div>
        <div className="inning">
          <span className={`arrow ${isTop || isMid ? '' : 'bot'}`}>{isTop || isMid ? '\u25B2' : '\u25BC'}</span>
          <span className="num">{inningNum}</span>
          <span className="lbl">{isMid ? 'Mid' : isTop ? 'Top' : 'Bot'}</span>
        </div>
      </div>

      <LineScore state={state} />

      <div className="glance">
        <Diamond bases={bases} />
        <div className="glance-right">
          <div className="outs">
            <span className="lbl">Out</span>
            <span className="dots">{dots}</span>
          </div>
          <div className="metric-row">
            <div className="metric">
              <span className="lbl">Count</span>
              <span className="count mono">{count.b}<small> – </small>{count.s}</span>
            </div>
          </div>
          <div className="dueup">
            <span className="lbl">Due up</span>
            <span className="spot mono">{dueSpot}</span>
            <span style={{ color: 'var(--ink-4)', fontSize: '11.5px' }}>{isTop || isMid ? 'Oakmont' : 'Riverside'}</span>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Hud, Diamond, LineScore });
