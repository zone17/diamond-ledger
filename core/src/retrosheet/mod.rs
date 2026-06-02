// TODO(T008): Implement the reduced-but-valid Retrosheet emitter.
//             8 record types: id · version · info · start · play · sub · com · data
//             Reduced grammar: S/D/T/H+fielder, K, W, IW, HP, single-fielder chains,
//             E$, SB%/CS%, modifiers /G /L /F /P /SF /SH, advances (-, X, simple E$).
//             Hard ~5% flag-for-manual: multi-out (runner) annotations, DP/TP, mid-string
//             errors, FC disambiguation, interference/obstruction, rare baserunning.
//             This emitter is REQUIRED from Phase A — it feeds the cwevent CI gate (D4).
//             See research.md D4 for the 3-layer gate spec and reduced-grammar details.
