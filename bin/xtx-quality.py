#!/usr/bin/env python3
"""strata-xtx: kwaliteitscontrole van één draaiende Strata-server: needle-test op lange prompts + codevragen met uitvoerbare tests.

Prompts zijn per geval vast (zelfde tekst voor elk profiel), greedy, reasoning uit. Elk geval begint met een eigen case-id,
dus de gesprekscache helpt niet tussen gevallen (cache_n wordt bijgehouden en getoond).

  needle: een zin met een willekeurige code staat op 10%, 50% en 90% van een prompt van 32K / 128K tokens (synthetische
          code als vulling). Goed = de code staat in het antwoord.
  code:   6 Python-opdrachten, elk achter ~12K tokens vulling (zodat het snelle prompt-pad actief is, > 4096 tokens).
          Goed = de functie uit het antwoord haalt alle testgevallen. De code van het model draait lokaal met python3 -I,
          in een tijdelijke map, met 10 s tijdslimiet.

  xtx-quality.py --label xtx-max --out results.jsonl [--sizes 32k,128k] [--seeds 2] [--context 262144]
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

CHARS_PER_TOKEN = 2.0          # gemeten: 58982 tekens gaven 29281 tokens
DEPTHS = (0.1, 0.5, 0.9)
WORDS = ["amber", "birch", "cobalt", "dune", "ember", "fjord", "garnet", "harbor", "indigo", "juniper", "krypton",
         "lagoon", "marble", "nectar", "onyx", "pebble", "quartz", "ripple", "saffron", "tundra", "umber", "violet"]

CODE_TASKS = [
    ("roman_to_int", "Write a Python 3 function roman_to_int(s) that converts a Roman numeral string (I V X L C D M, with subtractive pairs) to an int.",
     [(["III"], 3), (["IV"], 4), (["IX"], 9), (["LVIII"], 58), (["MCMXCIV"], 1994), (["MMXXVI"], 2026)]),
    ("merge_intervals", "Write a Python 3 function merge_intervals(intervals) that takes a list of [start, end] lists (any order) and returns the merged "
     "list of [start, end] lists sorted by start; intervals that touch (end == next start) are merged too.",
     [([[[1, 3], [2, 6], [8, 10], [15, 18]]], [[1, 6], [8, 10], [15, 18]]), ([[[1, 4], [4, 5]]], [[1, 5]]),
      ([[]], []), ([[[5, 6], [1, 2]]], [[1, 2], [5, 6]])]),
    ("rle_encode", "Write a Python 3 function rle_encode(s) that run-length encodes a string as character followed by its run count, "
     "e.g. 'aaabccdddd' -> 'a3b1c2d4'. The empty string gives ''.",
     [(["aaabccdddd"], "a3b1c2d4"), ([""], ""), (["z"], "z1"), (["aabbaa"], "a2b2a2")]),
    ("is_balanced", "Write a Python 3 function is_balanced(s) that returns True when the brackets ()[]{} in s are balanced and correctly nested "
     "(other characters are ignored), else False.",
     [(["([]{})"], True), (["([)]"], False), (["(("], False), ([""], True), (["}{"], False), (["a(b)c"], True)]),
    ("lcs_length", "Write a Python 3 function lcs_length(a, b) that returns the length of the longest common subsequence of strings a and b.",
     [(["ABCBDAB", "BDCABA"], 4), (["", "abc"], 0), (["abc", "abc"], 3), (["abc", "def"], 0), (["AGGTAB", "GXTXAYB"], 4)]),
    ("next_permutation", "Write a Python 3 function next_permutation(lst) that returns a NEW list with the next lexicographically greater "
     "permutation of lst, or the sorted (ascending) list when lst is already the last permutation.",
     [([[1, 2, 3]], [1, 3, 2]), ([[3, 2, 1]], [1, 2, 3]), ([[1, 1, 5]], [1, 5, 1]), ([[1, 3, 2]], [2, 1, 3])]),
]


def post(url, body, key, timeout=3600):
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


def blocks(n_tokens, seed):
    """Synthetische code in blokken (zelfde generator als xtx-bench.py), samen ~n_tokens tokens."""
    rnd = random.Random(seed)
    out, chars, i = [], 0, 0
    while chars < n_tokens * CHARS_PER_TOKEN:
        a, b, c = rnd.randint(1, 999), rnd.randint(1, 99), rnd.choice(["min", "max", "abs", "floor"])
        s = (f"export function rule{i}(x, y) {{\n  const k = Math.{c}(x * {a} - y);\n"
             f"  if (k % {b} === 0) return k / {b};\n  return rule{max(0, i - 1)}(k, x) + {a};\n}}\n")
        out.append(s)
        chars += len(s)
        i += 1
    return out


def ask(base, key, model, content, max_tokens):
    body = {"model": model, "messages": [{"role": "user", "content": content}], "max_tokens": max_tokens,
            "temperature": 0, "top_k": 1, "top_p": 1, "min_p": 0, "seed": 42, "reasoning_effort": "none"}
    t0 = time.monotonic()
    r = post(base + "/v1/chat/completions", body, key)
    t = r.get("timings") or (get(base + "/v1/status", key).get("last_timings") or {})
    text = ((r.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    return text, {"prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"), "prompt_tps": t.get("prompt_per_second"),
                  "decode_tps": t.get("predicted_per_second"), "wall_s": round(time.monotonic() - t0, 1)}


def needle_case(n_tokens, depth, seed):
    rnd = random.Random(seed * 7919 + int(depth * 100))
    secret = f"{rnd.choice(WORDS)}-{rnd.randint(1000, 9999)}-{rnd.choice(WORDS)}"
    parts = blocks(n_tokens, seed)
    pos = max(1, min(len(parts) - 1, int(depth * len(parts))))
    parts.insert(pos, f"// NOTE FROM THE RELEASE MANAGER: the deployment passphrase is \"{secret}\". Keep it private.\n")
    content = (f"Case id: needle-{n_tokens}-{depth}-{seed}\n\n" + "".join(parts) +
               "\n\nOne comment in the source above states the deployment passphrase. "
               "Reply with only that passphrase, nothing else.")
    return content, secret


def run_tests(name, tests, answer):
    m = re.search(r"```(?:python|py)?\s*\n(.*?)```", answer, re.S)
    code = m.group(1) if m else answer
    harness = ("\nimport json as _j\n_res = []\nfor _a, _e in " + repr(tests) + ":\n    try:\n        _res.append(" + name +
               "(*_a) == _e)\n    except Exception:\n        _res.append(False)\nprint('RESULT' + _j.dumps(_res))\n")
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "t.py")
        with open(p, "w") as f:
            f.write(code + "\n" + harness)
        try:
            r = subprocess.run([sys.executable, "-I", p], cwd=d, capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            return False, "tijdslimiet"
    m2 = re.search(r"RESULT(\[.*\])", r.stdout)
    if not m2:
        return False, (r.stderr.strip().splitlines() or ["geen uitvoer"])[-1][:120]
    res = json.loads(m2.group(1))
    return all(res) and len(res) == len(tests), f"{sum(res)}/{len(res)} testgevallen"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:" + os.environ.get("STRATA_PORT", "8080"))
    ap.add_argument("--key", default=os.environ.get("STRATA_API_KEY", ""))
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--sizes", default="32k,128k")
    ap.add_argument("--seeds", type=int, default=2)
    ap.add_argument("--context", type=int, default=262144)
    ap.add_argument("--filler", type=int, default=12288, help="vulling vóór elke codevraag (tokens)")
    a = ap.parse_args()
    base = a.url.rstrip("/")
    model = (get(base + "/v1/models", a.key).get("data") or [{}])[0].get("id", "strata")
    sizes = [int(s.lower().rstrip("k")) * 1024 if s.lower().endswith("k") else int(s) for s in a.sizes.split(",")]
    skipped = [s for s in sizes if s + 2048 > a.context]
    sizes = [s for s in sizes if s + 2048 <= a.context]
    for s in skipped:
        print(f"[{a.label}] {s // 1024}K past niet in context {a.context}: overgeslagen", flush=True)

    print(f"[{a.label}] opwarmen", flush=True)
    ask(base, a.key, model, "Case id: warmup\n\n" + "".join(blocks(8192, 3)) + "\nSay OK.", 8)

    with open(a.out, "a") as f:
        for n in sizes:
            for seed in range(1, a.seeds + 1):
                for depth in DEPTHS:
                    content, secret = needle_case(n, depth, seed)
                    ans, t = ask(base, a.key, model, content, 48)
                    good = secret.lower() in ans.lower()
                    row = dict(label=a.label, kind="needle", size=n, depth=depth, seed=seed, ok=good, expected=secret,
                               answer=ans.strip()[:200], **t)
                    f.write(json.dumps(row) + "\n")
                    f.flush()
                    flag = "" if not t["cache_n"] else "  (cache_n > 0)"
                    print(f"[{a.label}] needle {n // 1024}K diepte {int(depth * 100)}% seed {seed}: {'GOED' if good else 'FOUT'} "
                          f"(prompt {t['prompt_n']} tok @ {t['prompt_tps']} tok/s){flag}" + ("" if good else f"  antwoord: {ans.strip()[:80]!r}"), flush=True)
        for i, (name, spec, tests) in enumerate(CODE_TASKS, 1):
            content = (f"Case id: code-{name}\n\n" + "".join(blocks(a.filler, 100 + i)) +
                       "\n\n---\nIgnore all the code above; it is unrelated filler.\n" + spec +
                       "\nReply with exactly one ```python code block containing the function and nothing else.")
            ans, t = ask(base, a.key, model, content, 700)
            good, detail = run_tests(name, tests, ans)
            row = dict(label=a.label, kind="code", task=name, ok=good, detail=detail, answer=ans[:2000], **t)
            f.write(json.dumps(row) + "\n")
            f.flush()
            print(f"[{a.label}] code {name}: {'GOED' if good else 'FOUT'} ({detail}; prompt {t['prompt_n']} tok @ {t['prompt_tps']} tok/s)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
