//===----------------------------------------------------------------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//===----------------------------------------------------------------------===//
// Timing harness for benchmark_heap_to_stack.py. Each IR function consumes and
// frees its input. Allocation and initialization are outside the timed region.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef uint64_t (*Consumer)(uint64_t *, uint64_t);

#define DECLARE(SIZE)                                                           \
  extern uint64_t copy_loop_##SIZE(uint64_t *, uint64_t);                        \
  extern uint64_t direct_loop_##SIZE(uint64_t *, uint64_t);                      \
  extern uint64_t copy_call_##SIZE(uint64_t *, uint64_t);                        \
  extern uint64_t vector_copy_##SIZE(uint64_t *, uint64_t);                      \
  extern uint64_t vector_direct_##SIZE(uint64_t *, uint64_t)
DECLARE(4096);
DECLARE(65536);

struct Case {
  const char *Name;
  Consumer Consume;
  size_t Bytes;
  size_t Elements;
};

#define CASES(SIZE)                                                             \
  {"copy_loop", copy_loop_##SIZE, SIZE, 1},                                     \
      {"direct_loop", direct_loop_##SIZE, SIZE, 1},                             \
      {"copy_call", copy_call_##SIZE, SIZE, 1},                                 \
      {"vector_copy", vector_copy_##SIZE, SIZE, 16},                            \
      {"vector_direct", vector_direct_##SIZE, SIZE, 16}
static const struct Case Cases[] = {CASES(4096), CASES(65536)};
enum { NumCases = sizeof(Cases) / sizeof(Cases[0]), MaxBatch = 256 };

static double now(void) {
  struct timespec TS;
  if (clock_gettime(CLOCK_MONOTONIC, &TS)) {
    perror("clock_gettime");
    exit(1);
  }
  return TS.tv_sec + TS.tv_nsec * 1e-9;
}

static double measure(const struct Case *C) {
  size_t InputBytes = C->Bytes * C->Elements;
  size_t Words = InputBytes / sizeof(uint64_t);
  size_t Batch = 16 * 1024 * 1024 / InputBytes;
  if (Batch > MaxBatch)
    Batch = MaxBatch;
  uint64_t *Inputs[MaxBatch];
  uint64_t Expected = 0;
  for (size_t I = 0; I < Batch; ++I) {
    Inputs[I] = malloc(InputBytes);
    if (!Inputs[I]) {
      perror("malloc");
      exit(1);
    }
    for (size_t J = 0; J < Words; ++J)
      Inputs[I][J] = I + J + 1;
    Expected += Words * (I + 1) + Words * (Words - 1) / 2;
  }
  uint64_t Sum = 0;
  double Start = now();
  for (size_t I = 0; I < Batch; ++I)
    Sum += C->Consume(Inputs[I], C->Elements);
  double Elapsed = now() - Start;
  if (Sum != Expected) {
    fprintf(stderr, "%s: got %" PRIu64 ", expected %" PRIu64 "\n", C->Name,
            Sum, Expected);
    exit(1);
  }
  return Elapsed * 1e6 / (Batch * C->Elements);
}

static int compare(const void *A, const void *B) {
  double X = *(const double *)A, Y = *(const double *)B;
  return (X > Y) - (X < Y);
}

int main(int Argc, char **Argv) {
  int Rounds = Argc > 1 ? atoi(Argv[1]) : 101;
  if (Rounds < 1)
    return 1;
  double *Samples = calloc((size_t)Rounds * NumCases, sizeof(double));
  if (!Samples)
    return 1;
  // One warmup per case, followed by rotated, sequential measurement batches.
  for (int Round = 0; Round <= Rounds; ++Round)
    for (size_t Offset = 0; Offset < NumCases; ++Offset) {
      size_t Index = (Round + Offset) % NumCases;
      double Sample = measure(&Cases[Index]);
      if (Round)
        Samples[Index * Rounds + Round - 1] = Sample;
    }
  printf("Median of %d batches; checksum and free included; allocation excluded\n",
         Rounds);
  printf("%-14s %10s %12s\n", "Case", "Bytes/item", "us/item");
  for (size_t I = 0; I < NumCases; ++I) {
    double *Values = Samples + I * Rounds;
    qsort(Values, Rounds, sizeof(double), compare);
    double Median = (Values[(Rounds - 1) / 2] + Values[Rounds / 2]) / 2;
    printf("%-14s %10zu %12.2f\n", Cases[I].Name, Cases[I].Bytes, Median);
  }
  free(Samples);
  return 0;
}
