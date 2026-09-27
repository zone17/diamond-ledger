#!/usr/bin/env python3
"""voice-accuracy-compare.py — stage and judge the voice-accuracy harness (DL-157).

Two modes, both driven by evals/runners/voice-accuracy.sh (see its header for the gate story):

  stage   --cases C --variants V --pairs P --out DIR
      Reads the three corpora and writes the dl-score / dl-bias batch inputs under DIR:
        DIR/batches/<name>/input.txt        one transcript per line, in row order
        DIR/batches/<name>/rows.json        [{"role": "case"|"variant", "id": ...}] aligned to input
        DIR/batches/<name>/confidence.txt   the --confidence value for this batch
        DIR/batches/<name>/roster.txt       the --roster csv (absent for the no-roster batches)
        DIR/pairs/input.jsonl               the biasing pairs, verbatim rows
      KTD1: `--roster` is per-process, so variant rows are grouped by their EXACT roster value
      and the runner invokes dl-score once per (roster group, confidence). Rows without a
      roster — every canonical row plus roster-less variants — share the no-roster batches.
      Every base referenced by a variant is scored at confidence 100 in the no-roster batch;
      that is where base facts come from.

  compare --cases C --variants V --pairs P --run DIR [--rerun DIR2]
      Reads the batch outputs the runner wrote next to each input (out.jsonl) plus the dl-bias
      output (pairs/out.jsonl), judges them, prints the report and exits:
        0  PASS
        1  any confident-wrong row (R2), canonical regression, pair mismatch (R8),
           non-determinism (R6), corpus schema violation, or misaligned CLI output
        2  no work was done: zero variants OR zero pairs

Program output always reaches this file as DATA (paths on argv), never as source — see
docs/solutions/best-practices/eval-gate-construction-pitfalls.md.

Report labeling (R4 / evals/INTERFACE.md §2.4): every line carrying an accuracy-shaped number
(percent, ratio, count of rows that …) carries the literal label
`FIXTURE ROBUSTNESS (advisory — not field accuracy)`. The corpus is synthetic text, not field
audio; no line of this report is a field-accuracy claim. The hard-signal lines (confident-wrong
rows, canonical regressions, pair mismatches, determinism) are gate signals, not accuracy
numbers, and are printed without the label so they cannot be mistaken for advisory output.
"""

import argparse
import json
import os
import sys

LABEL = "FIXTURE ROBUSTNESS (advisory — not field accuracy)"
ADV = f"[{LABEL}]"

VARIANT_KINDS = {"mishear", "numeral", "filler", "roster", "roster_collision"}
ROSTER_KINDS = {"roster", "roster_collision"}
VARIANT_EXPECTS = {"same_as_base", "safe_surface", "text_layer_undetectable"}
PAIR_DECISIONS = {"override", "keep_base"}
CONFIDENCES = (100, 60)
NO_ROSTER = "r0"

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
NC = "\033[0m"


# ── Corpus loading + schema (R7 / R8) ──────────────────────────────────────────────────────────

def load_jsonl(path):
    """Rows of a JSON Lines file. A missing file is an empty corpus (the caller decides whether
    that is 'no work'); a malformed line is a schema error, never silently skipped."""
    rows, errors = [], []
    if not os.path.exists(path):
        return rows, errors
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                errors.append(f"{path}:{n}: invalid JSON ({e.msg})")
                continue
            if not isinstance(obj, dict):
                errors.append(f"{path}:{n}: not a JSON object")
                continue
            rows.append(obj)
    return rows, errors


def transcript_problem(text):
    """dl-score skips blank lines and lines whose first non-space char is '#', and reads one
    transcript per line. A transcript that would be dropped or split silently misaligns the
    batch, so reject it up front."""
    if not isinstance(text, str) or not text.strip():
        return "transcript must be a non-empty string"
    if text.lstrip().startswith("#"):
        return "transcript may not start with '#' (dl-score treats it as a comment)"
    if "\n" in text or "\r" in text:
        return "transcript may not contain a newline"
    return None


def validate_cases(cases):
    errors, seen = [], set()
    for c in cases:
        cid = c.get("id")
        if not isinstance(cid, str) or not cid:
            errors.append(f"cases: row without a string id: {json.dumps(c)[:80]}")
            continue
        if cid in seen:
            errors.append(f"cases {cid}: duplicate id")
        seen.add(cid)
        p = transcript_problem(c.get("transcript"))
        if p:
            errors.append(f"cases {cid}: {p}")
        for key in ("expect_ok", "expect_classification", "expect_judgment_required"):
            if key not in c:
                errors.append(f"cases {cid}: missing {key}")
    return errors


def validate_variants(variants, case_ids):
    errors, seen = [], set()
    for v in variants:
        vid = v.get("id")
        if not isinstance(vid, str) or not vid:
            errors.append(f"variants: row without a string id: {json.dumps(v)[:80]}")
            continue
        if vid in seen:
            errors.append(f"variants {vid}: duplicate id")
        seen.add(vid)
        if v.get("base_id") not in case_ids:
            errors.append(f"variants {vid}: base_id {v.get('base_id')!r} not found in cases")
        if v.get("kind") not in VARIANT_KINDS:
            errors.append(f"variants {vid}: kind {v.get('kind')!r} not in {sorted(VARIANT_KINDS)}")
        if v.get("expect") not in VARIANT_EXPECTS:
            errors.append(f"variants {vid}: expect {v.get('expect')!r} not in {sorted(VARIANT_EXPECTS)}")
        p = transcript_problem(v.get("transcript"))
        if p:
            errors.append(f"variants {vid}: {p}")
        roster = v.get("roster")
        if v.get("kind") in ROSTER_KINDS and roster is None:
            errors.append(f"variants {vid}: kind {v['kind']} requires a roster array")
        if roster is not None:
            if (not isinstance(roster, list) or not roster
                    or not all(isinstance(n, str) and n.strip() for n in roster)):
                errors.append(f"variants {vid}: roster must be a non-empty array of non-empty strings")
            elif any("," in n for n in roster):
                errors.append(f"variants {vid}: roster names may not contain ',' (dl-score --roster is csv)")
    return errors


def validate_pairs(pairs):
    errors, seen = [], set()
    for p in pairs:
        pid = p.get("id")
        if not isinstance(pid, str) or not pid:
            errors.append(f"pairs: row without a string id: {json.dumps(p)[:80]}")
            continue
        if pid in seen:
            errors.append(f"pairs {pid}: duplicate id")
        seen.add(pid)
        for key in ("base", "contextual_set", "expect_decision", "expect_text"):
            if key not in p:
                errors.append(f"pairs {pid}: missing {key}")
        if "biased" not in p or "base_confidence" not in p:
            errors.append(f"pairs {pid}: missing biased / base_confidence (use null when unknown)")
        if p.get("expect_decision") not in PAIR_DECISIONS:
            errors.append(f"pairs {pid}: expect_decision {p.get('expect_decision')!r} not in {sorted(PAIR_DECISIONS)}")
        if not isinstance(p.get("expect_text"), str):
            errors.append(f"pairs {pid}: expect_text must be a string")
    return errors


def load_corpora(args):
    cases, e1 = load_jsonl(args.cases)
    variants, e2 = load_jsonl(args.variants)
    pairs, e3 = load_jsonl(args.pairs)
    errors = e1 + e2 + e3
    errors += validate_cases(cases)
    case_ids = {c["id"] for c in cases if isinstance(c.get("id"), str)}
    errors += validate_variants(variants, case_ids)
    errors += validate_pairs(pairs)
    return cases, variants, pairs, errors


# ── Batching (KTD1) ────────────────────────────────────────────────────────────────────────────

def roster_key(roster):
    """Exact-roster grouping key: the JSON of the roster array as written (order + case kept)."""
    return json.dumps(roster, ensure_ascii=False) if roster else None


def plan_batches(cases, variants):
    """{(confidence, group_name): {"roster": [...] | None, "rows": [(role, id, transcript)]}}
    group names: r0 = no roster; r1, r2, … = distinct roster values in first-seen order."""
    groups = {None: NO_ROSTER}
    for v in variants:
        k = roster_key(v.get("roster"))
        if k not in groups:
            groups[k] = f"r{len(groups)}"
    batches = {}
    for conf in CONFIDENCES:
        for k, name in groups.items():
            rows = []
            if k is None:
                rows += [("case", c["id"], c["transcript"]) for c in cases]
            rows += [("variant", v["id"], v["transcript"]) for v in variants
                     if roster_key(v.get("roster")) == k]
            batches[(conf, name)] = {"roster": json.loads(k) if k else None, "rows": rows}
    return batches


def batch_dir(run, conf, name):
    return os.path.join(run, "batches", f"c{conf}-{name}")


def cmd_stage(args):
    cases, variants, pairs, errors = load_corpora(args)
    if errors:
        for e in errors:
            print(f"{RED}  corpus error{NC}: {e}", file=sys.stderr)
        return 1
    for (conf, name), b in plan_batches(cases, variants).items():
        d = batch_dir(args.out, conf, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "input.txt"), "w", encoding="utf-8") as fh:
            for _, _, t in b["rows"]:
                fh.write(t + "\n")
        with open(os.path.join(d, "rows.json"), "w", encoding="utf-8") as fh:
            json.dump([{"role": r, "id": i} for r, i, _ in b["rows"]], fh)
        with open(os.path.join(d, "confidence.txt"), "w") as fh:
            fh.write(str(conf))
        if b["roster"]:
            with open(os.path.join(d, "roster.txt"), "w", encoding="utf-8") as fh:
                fh.write(",".join(b["roster"]))
    pd = os.path.join(args.out, "pairs")
    os.makedirs(pd, exist_ok=True)
    with open(os.path.join(pd, "input.jsonl"), "w", encoding="utf-8") as fh:
        for p in pairs:
            fh.write(json.dumps(p, ensure_ascii=False) + "\n")
    print(f"staged {len(cases)} cases, {len(variants)} variants, {len(pairs)} pairs "
          f"into {len(CONFIDENCES) * (1 + len({roster_key(v.get('roster')) for v in variants} - {None}))} dl-score batches")
    return 0


# ── Reading CLI output (as data) ───────────────────────────────────────────────────────────────

def read_batch(run, conf, name, expected_rows):
    """Returns ({(role,id): scored_line}, [alignment errors]). Output is keyed by line ORDER and
    cross-checked against the echoed transcript, so a dropped or reordered line is loud."""
    d = batch_dir(run, conf, name)
    out_path = os.path.join(d, "out.jsonl")
    errors, results = [], {}
    if not os.path.exists(out_path):
        return results, [f"batch c{conf}-{name}: no out.jsonl (dl-score did not run)"]
    with open(os.path.join(d, "input.txt"), encoding="utf-8") as fh:
        inputs = [l.rstrip("\n") for l in fh]
    lines = []
    with open(out_path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                lines.append(json.loads(line))
            except json.JSONDecodeError as e:
                errors.append(f"batch c{conf}-{name}: out.jsonl:{n} invalid JSON ({e.msg})")
    if len(lines) != len(expected_rows) or len(inputs) != len(expected_rows):
        errors.append(f"batch c{conf}-{name}: {len(expected_rows)} rows sent, {len(lines)} scored lines received")
        return results, errors
    for (row, sent, got) in zip(expected_rows, inputs, lines):
        if got.get("transcript") != sent:
            errors.append(f"batch c{conf}-{name}: row {row['id']} echoed {got.get('transcript')!r}, sent {sent!r} (misaligned output)")
            continue
        results[(row["role"], row["id"])] = got
    return results, errors


def read_pairs_out(run, pairs):
    path = os.path.join(run, "pairs", "out.jsonl")
    errors, results = [], {}
    if not os.path.exists(path):
        return results, ["pairs: no out.jsonl (dl-bias did not run)"] if pairs else []
    lines = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                lines.append(json.loads(line))
            except json.JSONDecodeError as e:
                errors.append(f"pairs: out.jsonl:{n} invalid JSON ({e.msg})")
    if len(lines) != len(pairs):
        errors.append(f"pairs: {len(pairs)} rows sent, {len(lines)} lines received")
        return results, errors
    for p, got in zip(pairs, lines):
        if "error" in got and "decision" not in got:
            errors.append(f"pairs {p['id']}: dl-bias rejected the row: {got.get('error')}")
            continue
        if got.get("id") != p["id"]:
            errors.append(f"pairs {p['id']}: dl-bias echoed id {got.get('id')!r} (misaligned output)")
            continue
        results[p["id"]] = got
    return results, errors


# ── Judging ────────────────────────────────────────────────────────────────────────────────────

OUTCOME_FIELDS = ("classification", "needs", "judgment_required", "reisner_catalyst")


def outcome(a):
    return {k: a.get(k) for k in OUTCOME_FIELDS}


def canonical_problems(c, a):
    """transcript-score.sh comparison semantics, reused verbatim."""
    problems = []
    if a["ok"] != c["expect_ok"]:
        problems.append(f"ok={a['ok']} != {c['expect_ok']}")
    if a["classification"] != c["expect_classification"]:
        problems.append(f"cls={a['classification']!r} != {c['expect_classification']!r}")
    if a["judgment_required"] != c["expect_judgment_required"]:
        problems.append(f"judgment_required={a['judgment_required']} != {c['expect_judgment_required']}")
    if "expect_judgment_kind" in c and a.get("judgment_kind") != c["expect_judgment_kind"]:
        problems.append(f"judgment_kind={a.get('judgment_kind')!r} != {c['expect_judgment_kind']!r}")
    if "expect_reisner_catalyst" in c and a.get("reisner_catalyst") != c["expect_reisner_catalyst"]:
        problems.append(f"reisner_catalyst={a.get('reisner_catalyst')!r} != {c['expect_reisner_catalyst']!r}")
    if "expect_error" in c and c["expect_error"] not in (a.get("error") or ""):
        problems.append(f"error={a.get('error')!r} missing expected {c['expect_error']!r}")
    return problems


def is_safe_miss(a, base):
    """R3: the pipeline refused to score silently — a clarify (`ambiguous(`), out-of-grammar, or
    the same judgment kind the base surfaces."""
    err = a.get("error") or ""
    if a.get("classification") == "parse_error" and (err.startswith("ambiguous(") or err.startswith("out_of_grammar")):
        return True
    if a.get("judgment_kind") is not None and a.get("judgment_kind") == base.get("judgment_kind"):
        return True
    return False


def surfaces_judgment(a):
    return a.get("classification") == "judgment" or bool(a.get("judgment_required"))


def confident_wrong_reason(a, base):
    """R2: the only hard signal. Returns a reason string, or None."""
    if a.get("ok") is True and a.get("needs") in ("none", "confirm") and a.get("facts") != base.get("facts"):
        return "scored with confidence (ok, needs=%s) but facts differ from the base" % a.get("needs")
    if surfaces_judgment(a):
        if not surfaces_judgment(base):
            return "surfaces a judgment (%s) while the base is deterministic" % a.get("judgment_kind")
        if a.get("judgment_kind") != base.get("judgment_kind"):
            return "judgment kind %r differs from the base's %r" % (a.get("judgment_kind"), base.get("judgment_kind"))
    return None


def classify_variant(a, base):
    """One of: same | safe | confident_wrong | other, plus a reason for the non-'same' cases."""
    cw = confident_wrong_reason(a, base)
    if cw:
        return "confident_wrong", cw
    if a.get("facts") == base.get("facts") and outcome(a) == outcome(base):
        return "same", None
    if is_safe_miss(a, base):
        err = a.get("error") or ""
        how = "clarify" if err.startswith("ambiguous(") else ("out_of_grammar" if err.startswith("out_of_grammar") else "same judgment kind")
        return "safe", how
    return "other", "not scored as the base and not a recognized safe surface: cls=%s error=%r needs=%s" % (
        a.get("classification"), a.get("error"), a.get("needs"))


def asr_leg_wer(_hypothesis=None, _reference=None):
    """R1 hook: transcript WER is only meaningful once an ASR leg (audio → text) runs in this
    harness. No ASR leg is wired today (SpeechAnalyzer is iOS-26 device-bound), so this is a
    deliberate no-op that returns None and the report says 'not measured'. Wire it here."""
    return None


def clarify_rate(rows):
    """(numerator, denominator): share of parseable rows (not out_of_grammar) whose error starts
    with `ambiguous(`. Returns None when there is no parseable row."""
    parseable = [a for a in rows if not (a.get("error") or "").startswith("out_of_grammar")]
    if not parseable:
        return None
    n = sum(1 for a in parseable if (a.get("error") or "").startswith("ambiguous("))
    return n, len(parseable)


def pct(n, d):
    return f"{n}/{d} = {100.0 * n / d:.1f}%"


def files_differ(run_a, run_b):
    """Byte-diff every out.jsonl under run_a against run_b (R6). Returns the list of relative
    paths that differ or are missing on either side."""
    diffs = []
    outs = []
    for root, _, files in os.walk(run_a):
        for f in files:
            if f == "out.jsonl":
                outs.append(os.path.relpath(os.path.join(root, f), run_a))
    for rel in sorted(outs):
        pa, pb = os.path.join(run_a, rel), os.path.join(run_b, rel)
        if not os.path.exists(pb):
            diffs.append(rel + " (missing in rerun)")
            continue
        with open(pa, "rb") as fa, open(pb, "rb") as fb:
            if fa.read() != fb.read():
                diffs.append(rel)
    return diffs


def cmd_compare(args):
    cases, variants, pairs, errors = load_corpora(args)
    print("Voice-accuracy harness report (DL-157 / dl-score + dl-bias)")
    print("===========================================================")
    print(f"corpus: cases={args.cases}")
    print(f"        variants={args.variants}")
    print(f"        pairs={args.pairs}")
    print(f"scope: {LABEL} — synthetic text variants and hypothesis pairs; no field audio.")
    print()
    if errors:
        print(f"{RED}corpus schema errors ({len(errors)}):{NC}")
        for e in errors:
            print(f"  - {e}")
        print()
        print(f"{RED}Voice-accuracy harness: FAIL{NC} (corpus schema errors)")
        return 1
    if not variants or not pairs:
        print(f"{RED}no work: zero variants ({len(variants)}) or zero pairs ({len(pairs)}) — vacuous run, refusing to pass.{NC}")
        print()
        print(f"{RED}Voice-accuracy harness: NO WORK (exit 2){NC}")
        return 2

    # ── collect CLI output ──
    batches = plan_batches(cases, variants)
    results = {}          # (conf, role, id) -> scored line
    align_errors = []
    for (conf, name), b in batches.items():
        rows = [{"role": r, "id": i} for r, i, _ in b["rows"]]
        got, errs = read_batch(args.run, conf, name, rows)
        align_errors += errs
        for (role, rid), a in got.items():
            results[(conf, role, rid)] = a
    pair_out, errs = read_pairs_out(args.run, pairs)
    align_errors += errs
    if align_errors:
        print(f"{RED}CLI output errors ({len(align_errors)}):{NC}")
        for e in align_errors:
            print(f"  - {e}")
        print()
        print(f"{RED}Voice-accuracy harness: FAIL{NC} (CLI output missing or misaligned)")
        return 1

    # ── hard signals ──
    confident_wrong = []      # (variant, base_case, reason, actual, base_actual)
    canonical_regressions = []
    pair_mismatches = []
    by_kind = {}              # kind -> {"same":n,"safe":n,"confident_wrong":n,"other":n,"undetectable":n}
    safe_by_kind = {}         # kind -> {how: n}
    expectation_mismatches = []
    undetectable = []
    other_rows = []
    case_by_id = {c["id"]: c for c in cases}

    for c in cases:
        a = results[(100, "case", c["id"])]
        probs = canonical_problems(c, a)
        if probs:
            canonical_regressions.append((c, probs))

    for v in variants:
        a = results[(100, "variant", v["id"])]
        base = results[(100, "case", v["base_id"])]
        kind = v["kind"]
        counts = by_kind.setdefault(kind, {"same": 0, "safe": 0, "confident_wrong": 0, "other": 0, "undetectable": 0})
        cat, reason = classify_variant(a, base)
        if v["expect"] == "text_layer_undetectable":
            counts["undetectable"] += 1
            undetectable.append((v, cat))
            continue                                   # R7: counted, reported, excluded from R2
        counts[cat] += 1
        if cat == "confident_wrong":
            confident_wrong.append((v, case_by_id[v["base_id"]], reason, a, base))
        elif cat == "safe":
            safe_by_kind.setdefault(kind, {}).setdefault(reason, 0)
            safe_by_kind[kind][reason] += 1
        elif cat == "other":
            other_rows.append((v, reason))
        expected_cat = {"same_as_base": "same", "safe_surface": "safe"}[v["expect"]]
        if cat != expected_cat:
            expectation_mismatches.append((v, expected_cat, cat))

    decisions = {"override": 0, "keep_base": 0}
    for p in pairs:
        got = pair_out[p["id"]]
        decisions[got.get("decision")] = decisions.get(got.get("decision"), 0) + 1
        probs = []
        if got.get("decision") != p["expect_decision"]:
            probs.append(f"decision={got.get('decision')!r} != {p['expect_decision']!r}")
        if got.get("text") != p["expect_text"]:
            probs.append(f"text={got.get('text')!r} != {p['expect_text']!r}")
        if probs:
            pair_mismatches.append((p, probs, got))

    diffs = files_differ(args.run, args.rerun) if args.rerun else None

    # ── report: hard-signal block (gate signals; deliberately unlabeled) ──
    print("── Hard signal (Article VII / FR-008: never a confidently-scored wrong play) ──")
    colour = RED if confident_wrong else GREEN
    print(f"{colour}confident-wrong rows: {len(confident_wrong)}{NC}")
    for v, c, reason, a, base in confident_wrong:
        print(f"  {RED}CONFIDENT-WRONG{NC} base {c['id']} / variant {v['id']} (kind={v['kind']}, expect={v['expect']})")
        print(f"      base transcript:    {c['transcript']!r}")
        print(f"      variant transcript: {v['transcript']!r}")
        print(f"      why: {reason}")
        print(f"      expected facts (base): {json.dumps(base.get('facts'), sort_keys=True)}")
        print(f"      actual facts (variant): {json.dumps(a.get('facts'), sort_keys=True)}")
        print(f"      base outcome:    {json.dumps(outcome(base), sort_keys=True)}")
        print(f"      variant outcome: {json.dumps(outcome(a), sort_keys=True)}")
    colour = RED if canonical_regressions else GREEN
    print(f"{colour}canonical regressions: {len(canonical_regressions)}{NC}")
    for c, probs in canonical_regressions:
        print(f"  {RED}FAIL{NC} {c['id']:32} {c['transcript'][:40]!r}")
        for p in probs:
            print(f"         - {p}")
    colour = RED if pair_mismatches else GREEN
    print(f"{colour}pair mismatches: {len(pair_mismatches)}{NC}")
    for p, probs, got in pair_mismatches:
        print(f"  {RED}FAIL{NC} {p['id']:32} base={p['base']!r} biased={p.get('biased')!r}")
        for pr in probs:
            print(f"         - {pr}")
        print(f"         - dl-bias reason={got.get('reason')!r} distance={got.get('distance')}")
    if diffs is None:
        print(f"{YELLOW}determinism: not checked (no rerun supplied){NC}")
    elif diffs:
        print(f"{RED}determinism: DIVERGED across two identical runs — {len(diffs)} output file(s) differ{NC}")
        for d in diffs:
            print(f"  - {d}")
    else:
        print(f"{GREEN}determinism: identical raw dl-score/dl-bias output across two runs{NC}")
    print()

    # ── report: advisory block (every line labeled) ──
    print(f"── {LABEL} ──")
    n_var = len(variants)
    n_ud = len(undetectable)
    print(f"{ADV} corpus size: {len(cases)} canonical rows, {n_var} variant rows, {len(pairs)} biasing pairs")
    print(f"{ADV} variants judged against R2: {n_var - n_ud} (text_layer_undetectable excluded: {n_ud})")
    for kind in sorted(by_kind):
        k = by_kind[kind]
        print(f"{ADV} kind {kind:17} same={k['same']} safe={k['safe']} confident_wrong={k['confident_wrong']} "
              f"other={k['other']} undetectable={k['undetectable']}")
    for kind in sorted(safe_by_kind):
        hows = ", ".join(f"{how}={n}" for how, n in sorted(safe_by_kind[kind].items()))
        print(f"{ADV} safe misses for {kind}: {hows}")
    print(f"{ADV} expectation mismatches (variant scored differently from its expect label): {len(expectation_mismatches)}")
    for v, want, got in expectation_mismatches:
        print(f"{ADV}   {v['id']}: expect={v['expect']} → {want}, observed {got}")
    for v, reason in other_rows:
        print(f"{ADV}   other: {v['id']}: {reason}")
    for v, cat in undetectable:
        print(f"{ADV}   undetectable (excluded from R2): {v['id']} observed {cat}")
    for conf in CONFIDENCES:
        rows = [a for (cf, _, _), a in results.items() if cf == conf]
        cr = clarify_rate(rows)
        if cr is None:
            print(f"{ADV} clarify rate @{conf}: no parseable rows")
        else:
            print(f"{ADV} clarify rate @{conf}: {pct(*cr)} of parseable rows surfaced ambiguous(…)")
    print(f"{ADV} fact agreement is measured at confidence 100 only — the 60 run routes every parseable "
          f"row to clarify and yields empty facts by design")
    print(f"{ADV} pair decisions: override={decisions.get('override', 0)} keep_base={decisions.get('keep_base', 0)}")
    wer = asr_leg_wer()
    if wer is None:
        print(f"{ADV} transcript WER: not measured — no ASR leg runs in this harness (hook: asr_leg_wer)")
    else:
        print(f"{ADV} transcript WER: {wer}")
    print()

    # ── verdict ──
    reasons = []
    if confident_wrong:
        reasons.append(f"{len(confident_wrong)} confident-wrong row(s)")
    if canonical_regressions:
        reasons.append(f"{len(canonical_regressions)} canonical regression(s)")
    if pair_mismatches:
        reasons.append(f"{len(pair_mismatches)} pair mismatch(es)")
    if diffs:
        reasons.append("non-deterministic output")
    if reasons:
        print(f"{RED}Voice-accuracy harness: FAIL{NC} — " + "; ".join(reasons))
        return 1
    print(f"{GREEN}Voice-accuracy harness: PASS{NC} — no confident-wrong row, no canonical regression, "
          f"no pair mismatch" + ("" if diffs is None else ", deterministic"))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="mode", required=True)
    for mode in ("stage", "compare"):
        sp = sub.add_parser(mode)
        sp.add_argument("--cases", required=True)
        sp.add_argument("--variants", required=True)
        sp.add_argument("--pairs", required=True)
        if mode == "stage":
            sp.add_argument("--out", required=True)
        else:
            sp.add_argument("--run", required=True)
            sp.add_argument("--rerun", default=None)
    args = ap.parse_args(argv)
    return cmd_stage(args) if args.mode == "stage" else cmd_compare(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
