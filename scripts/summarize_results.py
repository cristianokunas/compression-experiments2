#!/usr/bin/env python3
"""
Summarize benchmark results across all experiments.

Usage:
    python3 scripts/summarize_results.py                  # all experiments
    python3 scripts/summarize_results.py results/RX7900XT_20260310_162153
    python3 scripts/summarize_results.py --tti-only       # show only real data
"""

import csv
import sys
import os
import json
from pathlib import Path
from collections import defaultdict

# ── Color helpers ──────────────────────────────────────────────────────────────
BOLD  = "\033[1m"
CYAN  = "\033[0;36m"
GREEN = "\033[0;32m"
YELLOW= "\033[1;33m"
BLUE  = "\033[0;34m"
DIM   = "\033[2m"
NC    = "\033[0m"

def hdr(text): return f"{BLUE}{BOLD}{'═'*60}\n  {text}\n{'═'*60}{NC}"
def sub(text): return f"{CYAN}{BOLD}── {text} ──{NC}"

# ── Data type classification ───────────────────────────────────────────────────
def data_type(filename):
    f = filename.lower()
    if "tti"    in f: return "TTI (real)"
    if "zeros"  in f: return "zeros"
    if "random" in f: return "random"
    if "binary" in f: return "binary"
    return "other"

def size_tier(filename):
    f = filename.lower()
    for t in ("xlarge", "large", "medium", "small"):
        if f.startswith(t): return t
    return "?"

# ── Load one CSV ───────────────────────────────────────────────────────────────
def _float(val):
    try: return float(val)
    except (ValueError, TypeError): return None

def load_csv(path):
    rows = []
    with open(path) as f:
        for row in csv.DictReader(f):
            try:
                size_bytes = float(row["FileSizeBytes"])
                comp_gb    = _float(row["CompThroughputGBs"])
                decomp_gb  = _float(row["DecompThroughputGBs"])

                # Prefer stored times (new runs); fall back to deriving from throughput
                comp_ms   = _float(row.get("CompTimeMs"))
                decomp_ms = _float(row.get("DecompTimeMs"))
                if comp_ms is None and comp_gb:
                    comp_ms = size_bytes / (comp_gb * 1e9) * 1000
                if decomp_ms is None and decomp_gb:
                    decomp_ms = size_bytes / (decomp_gb * 1e9) * 1000

                rows.append({
                    "algo":      row["Algorithm"],
                    "file":      row["TestFile"],
                    "size_mb":   float(row["FileSizeMB"]),
                    "size_bytes":size_bytes,
                    "chunk":     int(row["ChunkSize"]),
                    "ratio":     float(row["CompressionRatio"]),
                    "comp":      comp_gb,
                    "decomp":    decomp_gb,
                    "comp_ms":   comp_ms,
                    "decomp_ms": decomp_ms,
                    "dtype":     data_type(row["TestFile"]),
                    "tier":      size_tier(row["TestFile"]),
                })
            except (ValueError, KeyError):
                pass
    return rows

# ── Per-algorithm summary table ────────────────────────────────────────────────
def print_algo_summary(rows, title="Per-algorithm summary (all data types)"):
    print(sub(title))
    by_algo = defaultdict(list)
    for r in rows:
        by_algo[r["algo"]].append(r)

    fmt = f"  {{:<12}} {{:>10}} {{:>14}} {{:>14}} {{:>12}} {{:>12}}  {{:>5}}"
    print(fmt.format("Algorithm", "Ratio", "Comp GB/s", "Decomp GB/s",
                     "Comp ms", "Decomp ms", "N"))
    print("  " + "─"*78)
    for algo in ("lz4", "snappy", "cascaded"):
        if algo not in by_algo:
            continue
        data = by_algo[algo]
        avg_ratio  = sum(r["ratio"]  for r in data) / len(data)
        comp_vals  = [r["comp"]      for r in data if r["comp"]      is not None]
        decomp_vals= [r["decomp"]    for r in data if r["decomp"]    is not None]
        ctime_vals = [r["comp_ms"]   for r in data if r["comp_ms"]   is not None]
        dtime_vals = [r["decomp_ms"] for r in data if r["decomp_ms"] is not None]
        avg_comp   = sum(comp_vals)   / len(comp_vals)   if comp_vals   else None
        avg_decomp = sum(decomp_vals) / len(decomp_vals) if decomp_vals else None
        avg_ctime  = sum(ctime_vals)  / len(ctime_vals)  if ctime_vals  else None
        avg_dtime  = sum(dtime_vals)  / len(dtime_vals)  if dtime_vals  else None
        print(fmt.format(
            algo, f"{avg_ratio:.2f}x",
            f"{avg_comp:.2f}"   if avg_comp   is not None else "N/A",
            f"{avg_decomp:.2f}" if avg_decomp is not None else "N/A",
            f"{avg_ctime:.1f}"  if avg_ctime  is not None else "N/A",
            f"{avg_dtime:.1f}"  if avg_dtime  is not None else "N/A",
            len(data),
        ))
    print()

# ── TTI-only table ─────────────────────────────────────────────────────────────
def print_tti_table(rows):
    tti = [r for r in rows if r["dtype"] == "TTI (real)"]
    if not tti:
        print(f"  {YELLOW}No TTI rows found{NC}\n")
        return

    print(sub("TTI (real seismic data) — by size tier"))
    fmt = f"  {{:<12}} {{:<10}} {{:>8}} {{:>12}} {{:>12}} {{:>10}} {{:>10}}"
    print(fmt.format("Algorithm", "Tier", "Ratio",
                     "Comp GB/s", "Decomp GB/s", "Comp ms", "Decomp ms"))
    print("  " + "─"*76)

    tier_order = ["small", "medium", "large", "xlarge"]
    for algo in ("lz4", "snappy", "cascaded"):
        for tier in tier_order:
            match = [r for r in tti if r["algo"] == algo and r["tier"] == tier]
            if not match:
                continue
            r = match[0]
            cms = f"{r['comp_ms']:.1f}"   if r["comp_ms"]   is not None else "N/A"
            dms = f"{r['decomp_ms']:.1f}" if r["decomp_ms"] is not None else "N/A"
            print(fmt.format(algo, tier, f"{r['ratio']:.2f}x",
                             f"{r['comp']:.2f}", f"{r['decomp']:.2f}", cms, dms))
        print()

# ── Cross-experiment comparison (TTI large only) ───────────────────────────────
def print_cross_experiment(experiments):
    if len(experiments) < 2:
        return

    print(sub("Cross-experiment comparison — TTI large"))
    fmt = f"  {{:<28}} {{:<12}} {{:>10}} {{:>14}} {{:>14}}"
    print(fmt.format("Experiment", "Algorithm", "Ratio", "Comp GB/s", "Decomp GB/s"))
    print("  " + "─"*72)

    for name, rows in experiments:
        tti_large = [r for r in rows
                     if r["dtype"] == "TTI (real)" and r["tier"] == "large"]
        for algo in ("lz4", "snappy", "cascaded"):
            match = [r for r in tti_large if r["algo"] == algo]
            if not match:
                continue
            r = match[0]
            print(fmt.format(name[:28], algo, f"{r['ratio']:.2f}x",
                             f"{r['comp']:.2f}", f"{r['decomp']:.2f}"))
        print()

# ── Discover experiments ───────────────────────────────────────────────────────
def find_experiments(base_dir):
    results = []
    for d in sorted(Path(base_dir).iterdir()):
        csv_path = d / "results.csv"
        if d.is_dir() and csv_path.exists():
            results.append((d.name, load_csv(csv_path)))
    return results

# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    script_dir = Path(__file__).parent
    results_dir = script_dir.parent / "results"

    tti_only = "--tti-only" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]

    if args:
        # single experiment provided
        target = Path(args[0])
        if not (target / "results.csv").exists():
            print(f"No results.csv found in {target}")
            sys.exit(1)
        experiments = [(target.name, load_csv(target / "results.csv"))]
    else:
        experiments = find_experiments(results_dir)

    if not experiments:
        print(f"No experiment results found in {results_dir}")
        sys.exit(1)

    # ── Print each experiment ──────────────────────────────────────────────────
    for name, rows in experiments:
        meta_path = results_dir / name / "metadata.json"
        gpu_info = ""
        if meta_path.exists():
            with open(meta_path) as f:
                m = json.load(f)
            gpu_info = f"  {DIM}{m.get('gpu_name','?')} ({m.get('gpu_arch','?')}) — {m.get('iterations','?')} iterations{NC}"

        print(hdr(name))
        if gpu_info:
            print(gpu_info)
        print()

        if tti_only:
            print_tti_table(rows)
        else:
            print_algo_summary(rows)
            print_tti_table(rows)

    # ── Cross-experiment comparison ────────────────────────────────────────────
    if len(experiments) > 1:
        print(hdr("Cross-experiment comparison"))
        print_cross_experiment(experiments)


if __name__ == "__main__":
    main()
