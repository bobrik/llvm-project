# Heap-to-stack copy benchmark

`benchmark_heap_to_stack.py` generates LLVM IR for a checksum over copied and
directly read storage. It includes single 4 KiB and 64 KiB values, a read-only
call control, and repeated copies into an offset stack payload that model
consuming vector iteration. `benchmark_heap_to_stack.c` checks every result.
Allocation and initialization are outside the timed region; checksum and
deallocation are inside it. Cases run sequentially in rotated order.

From the repository root, after configuring an LLVM build in `build`:

```sh
cmake --build build --target opt llc llvm-config
python3 llvm/utils/benchmark_heap_to_stack.py --output build/copy-baseline
```

The script saves the input IR, optimized IR, assembly, executable, and a copy
of `opt` in the output directory. After rebuilding LLVM with an optimizer
change, choose a new output directory. The saved executable lets the original
optimizer be rerun for a sequential comparison:

```sh
python3 llvm/utils/benchmark_heap_to_stack.py --output build/copy-patched
python3 llvm/utils/benchmark_heap_to_stack.py --opt build/copy-baseline/opt --output build/copy-original-again
```

Baseline on an Apple M3, LLVM 24.0.0git at `ea8ba8302eea`, Release with
assertions, native AArch64 target. Values are medians of 101 batches, in
microseconds per element. The second run used the saved baseline executable
after the optimizer build changed; it shows the variation between runs.

| Case                  | First run (us/item) | Repeat (us/item) |
| --------------------- | ------------------: | ---------------: |
| `copy_loop_4096`      |                0.10 |             0.09 |
| `direct_loop_4096`    |                0.05 |             0.05 |
| `copy_call_4096`      |                0.06 |             0.05 |
| `vector_copy_4096`    |                0.08 |             0.07 |
| `vector_direct_4096`  |                0.05 |             0.05 |
| `copy_loop_65536`     |                2.14 |             1.75 |
| `direct_loop_65536`   |                0.87 |             0.73 |
| `copy_call_65536`     |                0.80 |             0.71 |
| `vector_copy_65536`   |                1.91 |             1.67 |
| `vector_direct_65536` |                0.80 |             0.70 |

Both copy shapes retain `llvm.memcpy` and a stack allocation in baseline
optimized IR. The directly read and read-only call controls have neither.
