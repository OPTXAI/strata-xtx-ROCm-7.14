#!/usr/bin/env python3
"""strata-xtx: meet één draaiende Strata-server (prompt- en decode-snelheid) met verse prompts.

Elke prompt begint met een unieke run-id, zodat niets uit de cache komt (cache_n wordt gecontroleerd). Tijden komen
van de server zelf (timings / /v1/status last_timings), niet van de wandklok. Greedy, reasoning uit.

  xtx-bench.py --label xtx --out results.jsonl [--sizes 8k,32k,64k] [--runs 3] [--decode 256]
"""
import argparse
import json
import os
import random
import statistics
import sys
import time
import urllib.request
import uuid


def post(url, body, key, timeout=1800):
    h = {"Content-Type": "application/json"}
    if key:
        h["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def get(url, key):
    h = {"Authorization": "Bearer " + key} if key else {}
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=30) as r:
        return json.loads(r.read())


def haystack(n_tokens: int, seed: int) -> str:
    """Synthetische code (~1,8 tekens per token: gemeten, 4K-label gaf 7,3K tokens bij 3,6), anders bij elke seed."""
    rnd = random.Random(seed)
    out, chars = [], 0
    i = 0
    while chars < n_tokens * 1.8:
        a, b, c = rnd.randint(1, 999), rnd.randint(1, 99), rnd.choice(["min", "max", "abs", "floor"])
        s = (f"export function rule{i}(x, y) {{\n  const k = Math.{c}(x * {a} - y);\n"
             f"  if (k % {b} === 0) return k / {b};\n  return rule{max(0, i - 1)}(k, x) + {a};\n}}\n")
        out.append(s)
        chars += len(s)
        i += 1
    return "".join(out)


def one(base, key, model, n_tokens, decode, seed):
    content = (f"Run id: {uuid.uuid4()}\n\n" + haystack(n_tokens, seed) +
               "\nReview this source and describe its behaviour precisely in a paragraph.")
    body = {"model": model, "messages": [{"role": "user", "content": content}], "max_tokens": decode,
            "temperature": 0, "top_k": 1, "top_p": 1, "min_p": 0, "seed": 42, "reasoning_effort": "none"}
    t0 = time.monotonic()
    r = post(base + "/v1/chat/completions", body, key)
    wall = time.monotonic() - t0
    t = r.get("timings") or (get(base + "/v1/status", key).get("last_timings") or {})
    return {"prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"), "prompt_tps": t.get("prompt_per_second"),
            "decode_n": t.get("predicted_n"), "decode_tps": t.get("predicted_per_second"), "wall_s": round(wall, 2),
            "finish": (r.get("choices") or [{}])[0].get("finish_reason")}


def ktok(n):
    """label = het echte aantal prompt-tokens (bv. 7.3K), niet de gevraagde grootte"""
    return f"{(n or 0) / 1000:.1f}K"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:" + os.environ.get("STRATA_PORT", "8080"))
    ap.add_argument("--key", default=os.environ.get("STRATA_API_KEY", ""))
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--sizes", default="8k,32k,64k")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--decode", type=int, default=256)
    a = ap.parse_args()
    base = a.url.rstrip("/")
    model = (get(base + "/v1/models", a.key).get("data") or [{}])[0].get("id", "strata")
    sizes = [int(s.lower().rstrip("k")) * 1024 if s.lower().endswith("k") else int(s) for s in a.sizes.split(",")]

    print(f"[{a.label}] opwarmen", flush=True)
    one(base, a.key, model, 300, 32, 1)
    one(base, a.key, model, sizes[0], 32, 2)
    rows = []
    with open(a.out, "a") as f:
        for n in sizes:
            for r in range(a.runs):
                res = one(base, a.key, model, n, a.decode, 1000 * n + r)
                res.update(label=a.label, size=n, run=r, at=int(time.time()))
                flag = "" if not res["cache_n"] else "  (!! cache_n > 0: telt niet)"
                print(f"[{a.label}] {ktok(res['prompt_n']):>5} run {r + 1}: prompt {res['prompt_n']} tok @ {res['prompt_tps']} tok/s, "
                      f"decode {res['decode_n']} @ {res['decode_tps']} tok/s{flag}", flush=True)
                f.write(json.dumps(res) + "\n")
                rows.append(res)
    for n in sizes:
        ok = [r for r in rows if r["size"] == n and not r["cache_n"]]
        if ok:
            pm = statistics.median(r["prompt_tps"] for r in ok if r["prompt_tps"])
            dm = statistics.median(r["decode_tps"] for r in ok if r["decode_tps"])
            print(f"[{a.label}] {ktok(statistics.median(r['prompt_n'] for r in ok))} mediaan: prompt {pm:.0f} tok/s, decode {dm:.1f} tok/s (n={len(ok)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
