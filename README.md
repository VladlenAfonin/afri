# Approximate FRI

This repository contains implementation of the "approximate FRI" protocol.
It is used to prove that a complex function is close to a complex polynomial in a similar way that the FRI protocol [\[BBHR18a\]][BBHR18a] allows to prove that a function is close to a polynomial over a finite field.

The overall goal here is creating the proof system for arbitrary approximate floating point computations.
Main idea is to adapt STARK [\[BBHR18b\]][BBHR18b] to complex numbers, which was heavily inspired by recent approximate Sum-Check protocol [\[BDGI+25\]][BDGI+25].

<!-- References. -->

[BBHR18a]: https://drops.dagstuhl.de/storage/00lipics/lipics-vol107-icalp2018/LIPIcs.ICALP.2018.14/LIPIcs.ICALP.2018.14.pdf
[BBHR18b]: https://eprint.iacr.org/2018/046.pdf
[BDGI+25]: https://eprint.iacr.org/2025/2152.pdf
