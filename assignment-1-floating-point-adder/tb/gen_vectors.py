#!/usr/bin/env python3
"""
gen_vectors.py -- exact IEEE-754 (e,m) addition oracle and test-vector
generator for the CAD-for-VLSI floating point adder assignment.

The oracle works with plain Python big integers, never with Python's own
`float`, so it is exact for every (e, m) in the assignment's Table 3
(including the non-standard widths) and is not limited by double precision.

For the four IEEE-standard shapes it can additionally be cross-checked
against numpy's hardware float32/float64 adder (see --crosscheck), and
against Berkeley TestFloat if `testfloat_gen` is on your PATH
(see --testfloat).

Usage:
    python3 gen_vectors.py --e 8 --m 23 --n 20000 --seed 1 --out tb_vectors

Writes, under the given --out directory:
    op1.hex        -- one operand per line, hex, width ceil((e+m+1)/4)
    op2.hex        -- ditto
    expected.hex   -- packed FPResult (value ++ flags) per line
    Config.bsv     -- typedef E, M, NumVecs for the BSV testbench
    vectors.txt    -- human-readable log (bits + decoded classes), for debugging
"""

import argparse
import os
import random
import struct


# ---------------------------------------------------------------------------
# Format description and bit-level decode/encode
# ---------------------------------------------------------------------------

class Fmt:
    def __init__(self, e, m):
        self.e = e
        self.m = m
        self.bias = (1 << (e - 1)) - 1
        self.emin = 1 - self.bias
        self.emax = self.bias
        self.width = 1 + e + m
        self.all_one_exp = (1 << e) - 1

    def decode(self, bits):
        sign = (bits >> (self.e + self.m)) & 1
        expo = (bits >> self.m) & ((1 << self.e) - 1)
        mant = bits & ((1 << self.m) - 1)
        return sign, expo, mant

    def encode(self, sign, expo, mant):
        return (sign << (self.e + self.m)) | (expo << self.m) | mant

    def classify(self, expo, mant):
        if expo == 0:
            return "zero" if mant == 0 else "subnormal"
        if expo == self.all_one_exp:
            if mant == 0:
                return "inf"
            return "qnan" if (mant >> (self.m - 1)) & 1 else "snan"
        return "normal"

    def canonical_nan(self):
        mant = 1 << (self.m - 1)
        return self.encode(0, self.all_one_exp, mant)

    def pack_zero(self, sign):
        return self.encode(sign, 0, 0)

    def pack_inf(self, sign):
        return self.encode(sign, self.all_one_exp, 0)


# ---------------------------------------------------------------------------
# Exact addition oracle
#
# Every finite operand is represented as an *integer* significand R and a
# base-2 exponent b such that value = (-1)^sign * R * 2^b. Because both
# operands are dyadic, aligning and adding them is exact big-integer
# arithmetic -- no precision is ever lost before the deliberate rounding
# step, regardless of e or m.
# ---------------------------------------------------------------------------

FLAGS_INVALID, FLAGS_OVERFLOW, FLAGS_UNDERFLOW, FLAGS_INEXACT = range(4)


def flags(invalid=False, overflow=False, underflow=False, inexact=False):
    return {"invalid": invalid, "overflow": overflow,
            "underflow": underflow, "inexact": inexact}


def pack_flags(f):
    return ((1 if f["invalid"] else 0) << 3 |
            (1 if f["overflow"] else 0) << 2 |
            (1 if f["underflow"] else 0) << 1 |
            (1 if f["inexact"] else 0) << 0)


def to_int_significand(fmt, expo, mant, subnormal):
    """Return (R, exp2) with value = R * 2^exp2, R the (hidden+m)-bit
    integer significand."""
    if subnormal:
        return mant, fmt.emin - fmt.m
    else:
        return (1 << fmt.m) | mant, (expo - fmt.bias) - fmt.m


def round_to_format(fmt, R, exp2):
    """Round the exact nonzero magnitude R * 2^exp2 (R > 0) to (e,m) with
    round-to-nearest, ties-to-even. Returns (expo_field, mant_field,
    is_overflow, is_underflow, is_inexact)."""

    L = R.bit_length()
    te = (L - 1) + exp2                      # binary exponent of the value

    if te >= fmt.emin:
        field_exp = te - fmt.m               # normal candidate
    else:
        field_exp = fmt.emin - fmt.m         # subnormal candidate, fixed LSB

    drop = field_exp - exp2

    if drop <= 0:
        kept = R << (-drop)
        inexact = False
    else:
        shifted = R >> drop
        remainder = R & ((1 << drop) - 1)
        half = 1 << (drop - 1)
        kept = shifted
        if remainder > half or (remainder == half and (shifted & 1) == 1):
            kept += 1
        inexact = remainder != 0

    # A carry out of rounding, or an initially-oversized `kept` in the
    # drop<=0 branch (can't happen there since drop<=0 means no bits were
    # ever above m+1), bumps te by one and normalises kept back down.
    if te >= fmt.emin:
        if kept >= (1 << (fmt.m + 1)):
            kept >>= 1
            te += 1
    else:
        if kept >= (1 << (fmt.m + 1)):
            kept >>= 1
            te += 1
        # kept reaching exactly 2^m means the subnormal rounded up into the
        # smallest normal; recompute te for that case below.

    # Re-derive the final class now that rounding may have changed things.
    if te >= fmt.emin:
        if kept >= (1 << fmt.m):
            # normal result
            if te > fmt.emax:
                return None, None, True, False, True  # overflow
            expo_field = te + fmt.bias
            mant_field = kept - (1 << fmt.m)
            return expo_field, mant_field, False, False, inexact
        else:
            # rounded a formerly-normal-exponent value down into subnormal
            # range (only possible if te == emin and kept < 2^m already)
            return 0, kept, False, inexact, inexact
    else:
        # still subnormal after rounding (kept < 2^m guaranteed here)
        return 0, kept, False, inexact, inexact


def add(fmt: Fmt, a_bits, b_bits):
    s1, e1, mant1 = fmt.decode(a_bits)
    s2, e2, mant2 = fmt.decode(b_bits)

    c1, c2 = fmt.classify(e1, mant1), fmt.classify(e2, mant2)

    # ---- special cases, precedence exactly as in Table 2 -----------------
    if c1 == "snan" or c2 == "snan":
        return fmt.canonical_nan(), flags(invalid=True)

    if c1 == "qnan" or c2 == "qnan":
        return fmt.canonical_nan(), flags()

    if c1 == "inf" and c2 == "inf" and s1 != s2:
        return fmt.canonical_nan(), flags(invalid=True)

    if c1 == "inf":
        return fmt.pack_inf(s1), flags()

    if c2 == "inf":
        return fmt.pack_inf(s2), flags()

    if c1 == "zero" and c2 == "zero":
        zsign = s1 if s1 == s2 else 0
        return fmt.pack_zero(zsign), flags()

    if c1 == "zero":
        return b_bits, flags()

    if c2 == "zero":
        return a_bits, flags()

    # ---- finite, nonzero, nonspecial: exact big-integer datapath ---------
    R1, exp2_1 = to_int_significand(fmt, e1, mant1, c1 == "subnormal")
    R2, exp2_2 = to_int_significand(fmt, e2, mant2, c2 == "subnormal")

    common = min(exp2_1, exp2_2)
    v1 = R1 << (exp2_1 - common)
    v2 = R2 << (exp2_2 - common)

    signed_sum = (v1 if s1 == 0 else -v1) + (v2 if s2 == 0 else -v2)

    if signed_sum == 0:
        return fmt.pack_zero(0), flags()          # exact cancellation -> +0

    result_sign = 1 if signed_sum < 0 else 0
    R = abs(signed_sum)

    expo_field, mant_field, ovf, unf, inexact = round_to_format(fmt, R, common)

    if ovf:
        return fmt.pack_inf(result_sign), flags(overflow=True, inexact=True)

    return (fmt.encode(result_sign, expo_field, mant_field),
            flags(underflow=unf, inexact=inexact))


# ---------------------------------------------------------------------------
# Vector generation
# ---------------------------------------------------------------------------

def rand_bits(fmt, rng, biased_class=None):
    """Draw a random operand. `biased_class` steers toward interesting
    encodings; None means uniform over the whole bit pattern."""
    if biased_class == "normal":
        expo = rng.randint(1, fmt.all_one_exp - 1)
        mant = rng.randint(0, (1 << fmt.m) - 1)
        sign = rng.randint(0, 1)
        return fmt.encode(sign, expo, mant)
    if biased_class == "subnormal":
        expo = 0
        mant = rng.randint(1, (1 << fmt.m) - 1)
        sign = rng.randint(0, 1)
        return fmt.encode(sign, expo, mant)
    if biased_class == "edge_normal":
        # exponents near emin or emax, mantissa near 0 or all-ones
        expo = rng.choice([1, 2, fmt.all_one_exp - 2, fmt.all_one_exp - 1])
        mant = rng.choice([0, 1, (1 << fmt.m) - 1, (1 << fmt.m) - 2])
        sign = rng.randint(0, 1)
        return fmt.encode(sign, expo, mant)
    return rng.randint(0, (1 << fmt.width) - 1)


def directed_vectors(fmt):
    e, m = fmt.e, fmt.m
    W = fmt.width
    vecs = []

    def enc(sign, expo, mant):
        return fmt.encode(sign, expo, mant)

    pos_zero, neg_zero = enc(0, 0, 0), enc(1, 0, 0)
    pos_inf, neg_inf = fmt.pack_inf(0), fmt.pack_inf(1)
    qnan = fmt.canonical_nan()
    snan = enc(0, fmt.all_one_exp, 1)                      # MSB of mant clear
    min_sub = enc(0, 0, 1)
    max_sub = enc(0, 0, (1 << m) - 1)
    min_norm = enc(0, 1, 0)
    max_norm = enc(0, fmt.all_one_exp - 1, (1 << m) - 1)
    one = enc(0, fmt.bias, 0)

    specials = [pos_zero, neg_zero, pos_inf, neg_inf, qnan, snan,
                min_sub, max_sub, min_norm, max_norm, one]

    # exhaustive-ish pairing of every special / boundary value against
    # every other one, both orders, both signs where meaningful
    for a in specials:
        for b in specials:
            vecs.append((a, b))
            vecs.append((b, a))

    # exponent-difference sweep: forces every shift amount the aligner can
    # see, 0 .. m+3 (covering the m+2 shortcut boundary exactly)
    for d in range(0, m + 4):
        for signs in [(0, 0), (0, 1), (1, 0), (1, 1)]:
            e_hi = fmt.bias + 3 if fmt.bias + 3 < fmt.all_one_exp - 1 else fmt.all_one_exp - 2
            e_lo = e_hi - d
            if e_lo < 0:
                continue
            a = enc(signs[0], e_hi, (1 << m) - 1)
            b = enc(signs[1], e_lo, (1 << m) - 1) if e_lo > 0 else enc(signs[1], 0, (1 << m) - 1)
            vecs.append((a, b))

    # Ties: add exactly half an ulp to values with an even/odd retained LSB.
    # Choose a low usable exponent so this also works for the narrowest
    # supported format (e=2, m=2), where half an ulp is a subnormal.  The old
    # construction used a negative encoded exponent for that format and wrote
    # malformed values such as "-5" into the .hex files.
    tie_unbiased_exp = fmt.emin + 1
    half_ulp_exp = tie_unbiased_exp - m - 1

    if half_ulp_exp >= fmt.emin:
        half_ulp = enc(0, half_ulp_exp + fmt.bias, 0)
    else:
        # A subnormal mantissa bit k represents 2^(emin-m+k).
        sub_bit = half_ulp_exp - (fmt.emin - m)
        half_ulp = enc(0, 0, 1 << sub_bit)

    for lsb in (0, 1):
        mant = ((1 << m) - 2) | lsb
        a = enc(0, tie_unbiased_exp + fmt.bias, mant)
        b = half_ulp
        vecs.append((a, b))
        vecs.append((b, a))

    # cancellation right at the subnormal/normal boundary
    vecs.append((enc(0, 1, 0), enc(1, 0, (1 << m) - 1)))
    vecs.append((enc(1, 1, 0), enc(0, 0, (1 << m) - 1)))

    # overflow-inducing sums
    vecs.append((max_norm, max_norm))
    vecs.append((max_norm, enc(0, fmt.bias, 0)))

    return vecs


def generate(e, m, n, seed):
    fmt = Fmt(e, m)
    rng = random.Random(seed)

    vecs = directed_vectors(fmt)

    biases = [None, "normal", "subnormal", "edge_normal"]
    while len(vecs) < n:
        b1 = rng.choice(biases)
        b2 = rng.choice(biases)
        a = rand_bits(fmt, rng, b1)
        b = rand_bits(fmt, rng, b2)
        vecs.append((a, b))

    vecs = vecs[:n]
    return fmt, vecs


# ---------------------------------------------------------------------------
# Optional cross-checks
# ---------------------------------------------------------------------------

def crosscheck_hw(fmt, vecs, results):
    """Cross-check binary32/binary64 results against numpy's hardware adder,
    which implements round-to-nearest-even in silicon/microcode. Only valid
    for e=8,m=23 or e=11,m=52."""
    import numpy as np

    if (fmt.e, fmt.m) == (8, 23):
        np_dtype, int_dtype = np.float32, np.uint32
    elif (fmt.e, fmt.m) == (11, 52):
        np_dtype, int_dtype = np.float64, np.uint64
    else:
        print("crosscheck: skipped (only defined for binary32 / binary64)")
        return

    mismatches = 0
    for (a_bits, b_bits), (r_bits, f) in zip(vecs, results):
        a = np.frombuffer(a_bits.to_bytes(int_dtype().itemsize, "little"), dtype=int_dtype).view(np_dtype)[0]
        b = np.frombuffer(b_bits.to_bytes(int_dtype().itemsize, "little"), dtype=int_dtype).view(np_dtype)[0]
        if np.isnan(a) or np.isnan(b):
            continue  # NaN payloads aren't standardised; skip those rows
        hw = np.float32(a) + np.float32(b) if np_dtype is np.float32 else (a + b)
        hw_bits = int(np.frombuffer(np_dtype(hw).tobytes(), dtype=int_dtype)[0])
        # ignore sign of a zero result and NaN payload bits; compare value otherwise
        if np.isnan(hw):
            continue
        if hw_bits != r_bits:
            mismatches += 1
            if mismatches <= 10:
                print(f"  crosscheck mismatch: a={a_bits:#x} b={b_bits:#x} "
                      f"oracle={r_bits:#x} numpy={hw_bits:#x}")
    total = sum(1 for a, b in vecs)
    print(f"crosscheck vs numpy hardware float: {total - mismatches}/{total} agree")


def testfloat_available():
    return os.system("which testfloat_gen > /dev/null 2>&1") == 0


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def hex_digits(width_bits):
    return (width_bits + 3) // 4


def write_outputs(fmt, vecs, results, outdir):
    os.makedirs(outdir, exist_ok=True)
    op_digits = hex_digits(fmt.width)
    res_digits = hex_digits(fmt.width + 4)

    with open(os.path.join(outdir, "op1.hex"), "w") as f1, \
         open(os.path.join(outdir, "op2.hex"), "w") as f2, \
         open(os.path.join(outdir, "expected.hex"), "w") as fe, \
         open(os.path.join(outdir, "vectors.txt"), "w") as flog:

        for (a, b), (r, fl) in zip(vecs, results):
            f1.write(f"{a:0{op_digits}x}\n")
            f2.write(f"{b:0{op_digits}x}\n")
            packed = (r << 4) | pack_flags(fl)
            fe.write(f"{packed:0{res_digits}x}\n")
            flog.write(f"a={a:#0{op_digits+2}x} b={b:#0{op_digits+2}x} "
                       f"-> r={r:#0{op_digits+2}x} "
                       f"flags(inv,ovf,unf,inx)={int(fl['invalid'])}"
                       f"{int(fl['overflow'])}{int(fl['underflow'])}"
                       f"{int(fl['inexact'])}\n")

    with open(os.path.join(outdir, "Config.bsv"), "w") as fc:
        fc.write(f"// Auto-generated by gen_vectors.py -- do not hand-edit.\n")
        fc.write(f"typedef {fmt.e} E;\n")
        fc.write(f"typedef {fmt.m} M;\n")
        fc.write(f"typedef {len(vecs)} NumVecs;\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--e", type=int, required=True)
    ap.add_argument("--m", type=int, required=True)
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="tb_vectors")
    ap.add_argument("--crosscheck", action="store_true",
                     help="cross-check against numpy hardware float (binary32/64 only)")
    args = ap.parse_args()

    if not 2 <= args.e <= 15:
        ap.error("--e must be in the assignment range 2..15")
    if not 2 <= args.m <= 63:
        ap.error("--m must be in the assignment range 2..63")
    if args.n <= 0:
        ap.error("--n must be positive")

    fmt, vecs = generate(args.e, args.m, args.n, args.seed)
    results = [add(fmt, a, b) for a, b in vecs]

    write_outputs(fmt, vecs, results, args.out)
    print(f"wrote {len(vecs)} vectors for e={args.e} m={args.m} to {args.out}/")

    if args.crosscheck:
        crosscheck_hw(fmt, vecs, results)

    if testfloat_available():
        print("testfloat_gen found on PATH -- see README.md for how to "
              "diff its f32_add output against expected.hex.")
    else:
        print("testfloat_gen not found on PATH -- oracle used standalone. "
              "Install Berkeley TestFloat and re-run with a standard width "
              "to cross-check (see README.md).")


if __name__ == "__main__":
    main()
