#!/usr/bin/env python3
"""strata-xtx: zet een tuning-profiel en de LXC-instellingen over het run-config dat setup.py schreef.

setup.py herschrijft "args" bij elke --setup/--update en laat met de hand toegevoegde engine-opties vallen
(upstream docs/INSTALL.md). Daarom wordt dit script na elke setup-run opnieuw gedraaid: het is idempotent.
Wat het zelf toevoegde, onthoudt het onder de sleutel "_xtx" (setup bewaart onbekende sleutels), zodat een
profielwissel de vorige toevoegingen eerst weghaalt.

Gebruik: xtx-config.py --config strata-iq3_s.json --profile xtx [--profiles-dir DIR] [--strata-dir DIR]
         [--vram-reserve-mib N] [--memory-limit-mib auto|N|0] [--resident-headroom-gib N]
         [--host H] [--api-key K] [--port P] [--table-dir DIR] [--dry-run]
"""
import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_profile(d: Path, name: str, seen=()):
    p = d / f"{name}.json"
    if not p.is_file():
        sys.exit(f"xtx-config: profiel {name!r} bestaat niet ({p})")
    if name in seen:
        sys.exit(f"xtx-config: cyclische inherits: {' -> '.join(seen + (name,))}")
    prof = json.loads(p.read_text(encoding="utf-8"))
    env, args = {}, []
    if prof.get("inherits"):
        env, args = load_profile(d, prof["inherits"], seen + (name,))
    env.update(prof.get("env") or {})
    for a in prof.get("args") or []:
        args = [x for x in args if x[0] != a[0]] + [list(a)]
    return env, args


def set_arg(args: list, flag: str, value=None) -> list:
    """flag (met value) in de args-lijst: een bestaande waarde vervangen, anders achteraan toevoegen."""
    out = list(args)
    if flag in out:
        i = out.index(flag)
        if value is not None:
            if i + 1 < len(out) and not out[i + 1].startswith("--"):
                out[i + 1] = str(value)
            else:
                out.insert(i + 1, str(value))
        return out
    return out + [flag] + ([str(value)] if value is not None else [])


def drop_arg(args: list, flag: str, had_value: bool) -> list:
    out = list(args)
    if flag in out:
        i = out.index(flag)
        del out[i:i + (2 if had_value and i + 1 < len(out) else 1)]
    return out


def meminfo_mib(key: str):
    try:
        for line in open("/proc/meminfo"):
            if line.startswith(key + ":"):
                return int(line.split()[1]) // 1024
    except OSError:
        pass
    return None


def cgroup_limit_mib():
    try:
        rel = open("/proc/self/cgroup").read().strip().split("::")[-1]
        v = Path("/sys/fs/cgroup" + rel, "memory.max").read_text().strip()
        return None if v == "max" else int(v) // (1 << 20)
    except (OSError, ValueError, IndexError):
        return None


def memory_limit(value: str):
    if value in ("", "0", "off", "none"):
        return None
    if value != "auto":
        return int(value)
    total = meminfo_mib("MemTotal")          # lxcfs: de limiet van de container
    lims = [x for x in (total, cgroup_limit_mib()) if x]
    return max(4096, min(lims) - 2048) if lims else None


def hipblaslt_version(lib_dirs):
    for d in lib_dirs or []:
        h = Path(d).parent / "include" / "hipblaslt" / "hipblaslt-version.h"
        try:
            t = h.read_text(encoding="utf-8")
            v = [int(re.search(rf"#define\s+HIPBLASLT_VERSION_{k}\s+(\d+)", t).group(1)) for k in ("MAJOR", "MINOR", "PATCH")]
            return v[0] * 100000 + v[1] * 100 + v[2]
        except (OSError, AttributeError, ValueError):
            continue
    return None


def table_rows(p: Path) -> int:
    try:
        return sum(1 for ln in p.read_text().splitlines()[2:] if ln.strip() and not ln.startswith("#"))
    except OSError:
        return 0


def unknown_switches(strata_dir: Path, names) -> list:
    """Schakelaars die niet (meer) in de upstream-bron voorkomen: hernoemd of verwijderd."""
    src = [strata_dir / "src", strata_dir / "include"]
    if not all(p.is_dir() for p in src):
        return []
    blob = []
    for root in src:
        for f in root.rglob("*"):
            if f.suffix in (".cpp", ".cu", ".hpp", ".h", ".cuh"):
                try:
                    blob.append(f.read_text(encoding="utf-8", errors="ignore"))
                except OSError:
                    pass
    text = "\n".join(blob)
    return [n for n in names if f'"{n}"' not in text]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--profile", default="xtx")
    ap.add_argument("--profiles-dir", default=str(HERE.parent / "profiles"))
    ap.add_argument("--strata-dir", default="")
    ap.add_argument("--vram-reserve-mib", default="")
    ap.add_argument("--memory-limit-mib", default="auto")
    ap.add_argument("--resident-headroom-gib", default="")
    ap.add_argument("--host", default="")
    ap.add_argument("--api-key", default=os.environ.get("XTX_API_KEY", ""))
    ap.add_argument("--port", default="")
    ap.add_argument("--table-dir", default="/var/lib/strata-xtx/hipblaslt")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    path = Path(a.config)
    cfg = json.loads(path.read_text(encoding="utf-8"))
    env_p, args_p = load_profile(Path(a.profiles_dir), a.profile)

    # 1. wat we de vorige keer toevoegden, eerst weghalen (setup kan het al weggegooid hebben)
    prev = cfg.get("_xtx") or {}
    env = dict(cfg.get("env") or {})
    for k, v in (prev.get("env") or {}).items():
        if env.get(k) == v:
            env.pop(k)
    for k, (orig, ours) in (prev.get("env_replaced") or {}).items():   # setup's eigen waarde terugzetten
        if env.get(k, ours) == ours:
            env[k] = orig
    args = list(cfg.get("args") or [])
    for flag, val in (prev.get("args_added") or []):
        args = drop_arg(args, flag, val is not None)
    for flag, (orig, ours) in (prev.get("args_replaced") or {}).items():   # vervangen setup-waarden terugzetten,
        i = args.index(flag) if flag in args else -1                         # tenzij setup ze intussen zelf herschreef
        if i >= 0 and i + 1 < len(args) and args[i + 1] == ours:
            args = set_arg(args, flag, orig)

    added_env, added_args, replaced, env_replaced = {}, [], {}, {}

    def put_arg(flag, val):
        nonlocal args
        if flag in args:
            i = args.index(flag)
            if val is not None and i + 1 < len(args) and not args[i + 1].startswith("--"):
                if args[i + 1] != str(val):
                    replaced[flag] = [args[i + 1], str(val)]
        else:
            added_args.append([flag, None if val is None else str(val)])
        args = set_arg(args, flag, val)

    def put_env(k, v):
        if env.get(k) == str(v):
            return
        if k in env:
            env_replaced[k] = [env[k], str(v)]
        else:
            added_env[k] = str(v)
        env[k] = str(v)

    # 2. het profiel
    for k, v in env_p.items():
        put_env(k, v)
    for item in args_p:
        put_arg(item[0], item[1] if len(item) > 1 else None)

    # 3. LXC / headless
    if a.vram_reserve_mib:
        put_arg("--vram-reserve-mib", a.vram_reserve_mib)
    lim = memory_limit(a.memory_limit_mib)
    if lim:
        put_arg("--memory-limit-mib", lim)
    if a.resident_headroom_gib:
        put_env("STRATA_RESIDENT_HEADROOM_GIB", a.resident_headroom_gib)

    # 4. een eigen gekalibreerde hipBLASLt-tabel (xtx-tune-hipblaslt) wint als ze bij arch + versie past en meer rijen heeft
    ver = hipblaslt_version(cfg.get("lib_dirs"))
    td = Path(a.table_dir)
    if ver and td.is_dir():
        for t in sorted(td.glob(f"*-hipblaslt-{ver}.txt")):
            cur = Path(env.get("STRATA_HIPBLASLT_TUNING", "")) if env.get("STRATA_HIPBLASLT_TUNING") else None
            if cur is None or table_rows(t) > table_rows(cur):
                put_env("STRATA_HIPBLASLT_TUNING", str(t))

    if a.host:
        cfg["host"] = a.host
    if a.api_key:
        cfg["api_key"] = a.api_key
    if a.port:
        cfg["port"] = int(a.port)

    cfg["env"] = env
    cfg["args"] = args
    cfg["_xtx"] = {"profile": a.profile, "env": added_env, "args_added": added_args, "args_replaced": replaced, "env_replaced": env_replaced,
                   "hipblaslt_version": ver}

    gone = unknown_switches(Path(a.strata_dir), list(env_p)) if a.strata_dir else []
    for n in gone:
        print(f"  !!  {n} komt niet meer voor in de upstream-bron (hernoemd of verwijderd?): werkt nu niet", file=sys.stderr)

    print(f"  profiel {a.profile}: {len(added_env)} env, {len(added_args)} args toegevoegd, "
          f"{len(replaced) + len(env_replaced)} setup-waarde(n) vervangen" + (f", hipBLASLt {ver}" if ver else ""))
    for k, v in sorted(env.items()):
        print(f"    env  {k}={v}")
    print("    args " + " ".join(args))
    if a.dry_run:
        return 0
    bak = path.with_name(path.name + ".xtx-bak")
    shutil.copy2(path, bak)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(cfg, indent=1), encoding="utf-8")
    try:
        st = path.stat()
        os.chown(tmp, st.st_uid, st.st_gid)
    except (OSError, AttributeError):
        pass
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
