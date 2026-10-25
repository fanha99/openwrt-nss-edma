#!/usr/bin/env python3
"""Summarise page_owner data from the CR8806.

Reads either /sys/kernel/debug/page_owner_stacks/show_stacks (aggregated,
"nr_base_pages: N" after each stack) or a raw /sys/kernel/debug/page_owner
dump ("Page allocated via order N ..." records), from stdin or a file, and
prints the call stacks holding the most memory.

  ssh root@router cat /sys/kernel/debug/page_owner_stacks/show_stacks | ./page-owner-top.py
  ./page-owner-top.py dump.txt -n 30 --frames 8
"""
import argparse
import collections
import re
import sys

ORDER_RE = re.compile(r"^Page allocated via order (\d+)")
NR_RE = re.compile(r"^\s*nr_base_pages:\s*(\d+)")
FRAME_RE = re.compile(r"^\s+(\S+)")

# Frames that say nothing about who asked for the memory.
GENERIC = (
    "post_alloc_hook", "get_page_from_freelist", "__alloc_pages", "alloc_pages",
    "__alloc_frozen_pages", "alloc_frozen_pages", "__folio_alloc", "folio_alloc",
    "prep_new_page", "alloc_pages_mpol", "alloc_pages_noprof", "__alloc_pages_noprof",
    "_noprof", "allocate_slab", "new_slab", "___slab_alloc", "__slab_alloc",
    "kmalloc_trace", "__kmalloc", "kmem_cache_alloc", "__kmem_cache_alloc",
    "alloc_slab_page", "__page_frag_alloc", "page_frag_alloc", "__page_frag_cache_refill",
)


def frame_name(line):
    m = FRAME_RE.match(line)
    if not m:
        return None
    return m.group(1).split("+")[0]


def interesting(frames, depth):
    out = [f for f in frames if not any(g in f for g in GENERIC)]
    return tuple(out[:depth]) if out else tuple(frames[:depth])


def parse_stacks(lines, depth):
    """show_stacks: frames, then 'nr_base_pages: N', then a blank line."""
    totals = collections.Counter()
    frames = []
    for line in lines:
        m = NR_RE.match(line)
        if m:
            totals[interesting(frames, depth)] += int(m.group(1))
            frames = []
            continue
        name = frame_name(line)
        if name:
            frames.append(name)
    return totals


def parse_raw(lines, depth):
    """page_owner: one record per allocation, separated by blank lines."""
    totals = collections.Counter()
    order = None
    frames = []

    def flush():
        if order is not None:
            totals[interesting(frames, depth)] += 1 << order

    for line in lines:
        m = ORDER_RE.match(line)
        if m:
            flush()
            order, frames = int(m.group(1)), []
            continue
        if line.startswith("PFN") or not line.strip():
            continue
        name = frame_name(line)
        if name and order is not None:
            frames.append(name)
    flush()
    return totals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?", help="input file (default stdin)")
    ap.add_argument("-n", type=int, default=25, help="stacks to show")
    ap.add_argument("--frames", type=int, default=6, help="frames per stack")
    args = ap.parse_args()

    lines = open(args.file, errors="replace") if args.file else sys.stdin
    lines = list(lines)
    raw = any(ORDER_RE.match(l) for l in lines[:50])
    totals = parse_raw(lines, args.frames) if raw else parse_stacks(lines, args.frames)

    total = sum(totals.values())
    print(f"{'raw page_owner' if raw else 'show_stacks'}: {total} pages = {total * 4 / 1024:.1f} MiB in {len(totals)} stacks\n")
    for stack, pages in totals.most_common(args.n):
        print(f"{pages * 4 / 1024:7.2f} MiB  {pages:6d} pages  " + " <- ".join(stack))


if __name__ == "__main__":
    main()
