# Approximate FRI

This repository contains implementation of the "approximate FRI" protocol.
It is used to prove that a complex function is close to a complex polynomial in a similar way that the FRI protocol [\[BBHR18a\]][BBHR18a] allows to prove that a function is close to a polynomial over a finite field.

The overall goal here is creating the proof system for arbitrary approximate floating point computations.
Main idea is to adapt STARK [\[BBHR18b\]][BBHR18b] to complex numbers, which was heavily inspired by recent approximate Sum-Check protocol [\[BDGI+25\]][BDGI+25].

<!-- References. -->

[BBHR18a]: https://drops.dagstuhl.de/storage/00lipics/lipics-vol107-icalp2018/LIPIcs.ICALP.2018.14/LIPIcs.ICALP.2018.14.pdf
[BBHR18b]: https://eprint.iacr.org/2018/046.pdf
[BDGI+25]: https://eprint.iacr.org/2025/2152.pdf

## Running Benchmarks

### aFRI/FRI

- Prover.

```bash
zig build bench-fri -Doptimize=ReleaseFast -- --from 10 --to 20 --budget 30 -p prover -s csv >results/fri-prover.csv
```

```bash
zig build bench-afri -Doptimize=ReleaseFast -- --from 10 --to 20 --budget 30 -p prover -s csv >results/afri-prover.csv
```

- Verifier.

```bash
zig build bench-fri -Doptimize=ReleaseFast -- --from 10 --to 20 --budget 30 -p verifier -s csv >results/fri-verifier.csv
```

```bash
zig build bench-afri -Doptimize=ReleaseFast -- --from 10 --to 20 --budget 30 -p verifier -s csv >results/afri-verifier.csv
```

### aSTARK/STARK

- Prover.

```bash
zig build bench-stark -Doptimize=ReleaseFast -- --from 4 --to 12 --budget 10 -p prover -s csv >results/stark-prover.csv
```

```bash
zig build bench-astark -Doptimize=ReleaseFast -- --from 4 --to 12 --budget 10 -p prover -s csv >results/astark-prover.csv
```

- Verifier.

```bash
zig build bench-stark -Doptimize=ReleaseFast -- --from 4 --to 12 --budget 10 -p verifier -s csv >results/stark-verifier.csv
```

```bash
zig build bench-astark -Doptimize=ReleaseFast -- --from 4 --to 12 --budget 10 -p verifier -s csv >results/astark-verifier.csv
```

### FRI Hash Functions

- Prover.

```bash
zig build bench-fri -Doptimize=ReleaseFast -Dhash=sha3 -- --from 8 --to 13 --budget 10 -p prover -s csv >results/fri-prover-sha3.csv
```

```bash
zig build bench-fri -Doptimize=ReleaseFast -Dhash=streebog -- --from 8 --to 13 --budget 10 -p prover -s csv >results/fri-prover-streebog.csv
```

- Verifier.

```bash
zig build bench-fri -Doptimize=ReleaseFast -Dhash=sha3 -- --from 8 --to 13 --budget 10 -p verifier -s csv >results/fri-verifier-sha3.csv
```

```bash
zig build bench-fri -Doptimize=ReleaseFast -Dhash=streebog -- --from 8 --to 13 --budget 10 -p verifier -s csv >results/fri-verifier-streebog.csv
```
