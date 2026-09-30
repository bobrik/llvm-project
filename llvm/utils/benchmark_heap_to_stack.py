#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Build and run the heap-to-stack copy benchmark using this checkout's LLVM.

Run before and after optimizer changes, using distinct output directories:
  python3 llvm/utils/benchmark_heap_to_stack.py --output build/copy-baseline
  python3 llvm/utils/benchmark_heap_to_stack.py --output build/copy-patched

To rerun the original optimizer after patching, use the saved executable:
  python3 llvm/utils/benchmark_heap_to_stack.py --opt build/copy-baseline/opt --output build/copy-original-again

The output directory retains the input IR, optimized IR, assembly, and binary.
The binary can also be rerun directly. No Rust rebuild is needed.
"""

import argparse
from pathlib import Path
import shutil
import subprocess


def loop(pointer, words, predecessor="entry", initial="0"):
    return f"""
loop:
  %i = phi i64 [ 0, %{predecessor} ], [ %next, %loop ]
  %sum = phi i64 [ {initial}, %{predecessor} ], [ %added, %loop ]
  %p = getelementptr inbounds i64, ptr %{pointer}, i64 %i
  %value = load i64, ptr %p, align 8
  %added = add i64 %sum, %value
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, {words}
  br i1 %done, label %exit, label %loop
"""


def cases(size):
    words = size // 8
    copy = f"""  %tmp = alloca [{words} x i64], align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %tmp, ptr align 8 %src, i64 {size}, i1 false)
"""
    result = ""
    for kind in ("copy_loop", "direct_loop", "copy_call"):
        result += f"""
define i64 @{kind}_{size}(ptr noalias align 8 dereferenceable({size}) %src, i64 %count) {{
entry:
"""
        if kind != "direct_loop":
            result += copy
        if kind == "copy_call":
            result += f"  %added = call i64 @sum_{size}(ptr %tmp)\n"
        else:
            result += "  br label %loop\n"
            result += loop("src" if kind == "direct_loop" else "tmp", words)
            result += "\nexit:\n"
        result += "  call void @free(ptr %src)\n  ret i64 %added\n}\n"
    result += f"""
define internal i64 @sum_{size}(ptr readonly captures(none) align 8 dereferenceable({size}) %src) noinline {{
entry:
  br label %loop
{loop("src", words)}
exit:
  ret i64 %added
}}
"""
    for kind in ("vector_copy", "vector_direct"):
        result += f"""
define i64 @{kind}_{size}(ptr noalias align 8 %src, i64 %count) {{
entry:
"""
        if kind == "vector_copy":
            result += f"""  %tmp = alloca [{size + 8} x i8], align 8
  %payload = getelementptr inbounds i8, ptr %tmp, i64 8
"""
        result += f"""  %empty = icmp eq i64 %count, 0
  br i1 %empty, label %finish, label %outer

outer:
  %element = phi ptr [ %src, %entry ], [ %following, %exit ]
  %index = phi i64 [ 0, %entry ], [ %index.next, %exit ]
  %total = phi i64 [ 0, %entry ], [ %added, %exit ]
"""
        if kind == "vector_copy":
            result += f"""  call void @llvm.lifetime.start.p0(ptr %tmp)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %payload, ptr align 8 %element, i64 {size}, i1 false)
"""
        result += "  br label %loop\n"
        result += loop(
            "payload" if kind == "vector_copy" else "element", words, "outer", "%total"
        )
        result += "\nexit:\n"
        if kind == "vector_copy":
            result += "  call void @llvm.lifetime.end.p0(ptr %tmp)\n"
        result += f"""  %following = getelementptr inbounds i8, ptr %element, i64 {size}
  %index.next = add nuw i64 %index, 1
  %finished = icmp eq i64 %index.next, %count
  br i1 %finished, label %finish, label %outer

finish:
  %result = phi i64 [ 0, %entry ], [ %added, %exit ]
  call void @free(ptr %src)
  ret i64 %result
}}
"""
    return result


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--opt", type=Path, help="opt executable (defaults to build/bin/opt)")
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--rounds", type=int, default=101)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    tools = args.build_dir.resolve() / "bin"
    opt = args.opt.resolve() if args.opt else tools / "opt"
    saved_opt = args.output.resolve() / "opt"
    if opt != saved_opt:
        shutil.copy2(opt, saved_opt)
    triple = subprocess.check_output(
        [str(tools / "llvm-config"), "--host-target"], text=True
    ).strip()
    source = args.output / "input.ll"
    optimized = args.output / "optimized.ll"
    obj = args.output / "cases.o"
    binary = args.output / "benchmark"
    source.write_text(
        f'target triple = "{triple}"\n'
        'declare void @free(ptr allocptr captures(address)) nounwind allockind("free")\n'
        "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1 immarg)\n"
        "declare void @llvm.lifetime.start.p0(ptr captures(none))\n"
        "declare void @llvm.lifetime.end.p0(ptr captures(none))\n"
        + cases(4096)
        + cases(65536)
    )
    run(opt, "--version")
    run(
        opt, "-S", "-verify-each", "-mcpu=native",
        "-passes=default<O3>", source, "-o", optimized,
    )
    run(tools / "llc", "-mcpu=native", "-filetype=obj", optimized, "-o", obj)
    run(tools / "llc", "-mcpu=native", optimized, "-o", args.output / "cases.s")
    run(args.cc, "-O2", Path(__file__).with_suffix(".c"), obj, "-o", binary)
    run(binary.resolve(), args.rounds)


if __name__ == "__main__":
    main()
