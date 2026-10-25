#!/usr/bin/env python3
"""Compare two page_owner show_stacks snapshots, stack by stack.

  page-owner-diff.py before.txt after.txt [frames]
"""
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location(
    "pot", os.path.join(os.path.dirname(os.path.abspath(__file__)), "page-owner-top.py"))
pot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pot)

a, b = sys.argv[1], sys.argv[2]
depth = int(sys.argv[3]) if len(sys.argv) > 3 else 5
A = pot.parse_stacks(open(a), depth)
B = pot.parse_stacks(open(b), depth)
d = sorted(((B[k] - A[k], k) for k in set(A) | set(B)), key=lambda x: x[0])

print("biggest increases:")
for v, k in reversed(d[-15:]):
    if v > 0:
        print(f"  +{v * 4 / 1024:6.2f} MiB ({A[k] * 4 / 1024:6.2f} -> {B[k] * 4 / 1024:6.2f})  " + " <- ".join(k))
print("biggest decreases:")
for v, k in d[:8]:
    if v < 0:
        print(f"  {v * 4 / 1024:7.2f} MiB ({A[k] * 4 / 1024:6.2f} -> {B[k] * 4 / 1024:6.2f})  " + " <- ".join(k))
