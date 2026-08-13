#!/usr/bin/env bash
#
# Integrity and safety audit for the seed corpora in seeds/.
#
# Run this before publishing a refreshed archive. It answers two questions:
#   1. Are these the exact bytes we intended to ship?      (SHA256SUMS)
#   2. Is it safe to publish them under the ZF org name?   (the audit checks)
#
# It deliberately does NOT judge corpus quality or coverage -- only that the
# contents are what they claim to be and carry nothing that should not be
# public. No network access; everything runs against the working tree.
#
# Usage: ./verify.sh
# Exit:  0 all checks passed, 1 one or more failed.

set -euo pipefail

cd "$(dirname "$0")"

# The 15 fuzz targets in ZcashFoundation/zebra zebra-fuzz/fuzz/fuzz_targets/.
# Archive names are a contract with the OSS-Fuzz build.sh, which looks each one
# up by target name -- a rename silently removes that target's seeds.
TARGETS=(
    addr_message_fuzz
    address_fuzz
    block_deep_fuzz
    block_deserialize
    equihash_fuzz
    ironwood_value_balance_codec_fuzz
    jsonrpsee_envelope_fuzz
    note_commitment_tree_fuzz
    p2p_deep_fuzz
    p2p_message_parse
    rpc_handler_fuzz
    script_flag_matrix_fuzz
    script_verify_fuzz
    v6_transaction_fuzz
    v6_transaction_semantic_fuzz
)

# Secret and key material. Finding any of these in chain-derived data would mean
# something other than chain data got swept into the corpus.
SECRET_PATTERNS=(
    -----BEGIN
    'PRIVATE KEY'
    xprv
    zxviews
    secret-extended-key
    zxsecret
    'AKIA[0-9A-Z]{16}'
    'ghp_[A-Za-z0-9]{30}'
    github_pat_
)

# Paths that would indicate the collecting machine's filesystem leaked in.
PATH_PATTERNS=(
    '/home/[a-z]'
    '/Users/[A-Za-z]'
    '\.ssh/'
    'id_rsa'
    '/root/'
)

FAILURES=0
WORK=""

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }

for tool in unzip sha256sum file; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "== 1. archive manifest =="
for t in "${TARGETS[@]}"; do
    [ -f "seeds/${t}_seed_corpus.zip" ] \
        || fail "missing seeds/${t}_seed_corpus.zip"
done
extra="$(comm -13 \
    <(printf '%s\n' "${TARGETS[@]}" | sed 's|$|_seed_corpus.zip|' | sort) \
    <(cd seeds && ls -1 ./*.zip | sed 's|^\./||' | sort))"
[ -z "$extra" ] || fail "archives with no matching fuzz target: $(echo "$extra" | tr '\n' ' ')"
# if/fi rather than `[ ... ] && pass`: a bare test as the last command of a line
# returns non-zero when it fails, and set -e would abort the run at the first
# problem instead of reporting every check.
if [ "$FAILURES" -eq 0 ]; then
    pass "all ${#TARGETS[@]} archives present, none extraneous"
fi

echo "== 2. checksums =="
if [ -f SHA256SUMS ]; then
    if (cd seeds && sha256sum -c --quiet ../SHA256SUMS) 2>/dev/null; then
        pass "all archives match SHA256SUMS"
    else
        fail "checksum mismatch -- archives differ from SHA256SUMS"
    fi
else
    fail "SHA256SUMS is missing"
fi

echo "== 3. extracting =="
WORK="$(mktemp -d)"
for z in seeds/*.zip; do
    unzip -qq -o "$z" -d "$WORK/$(basename "${z%.zip}")" 2>/dev/null \
        || fail "could not extract $z"
done
entries="$(find "$WORK" -type f | wc -l)"
raw="$(du -sb "$WORK" | cut -f1)"
packed="$(du -cb seeds/*.zip | tail -1 | cut -f1)"
pass "$entries entries, $raw bytes uncompressed from $packed bytes packed"

echo "== 4. decompression ratio =="
# Guards the OSS-Fuzz builder and anyone unzipping these against a zip bomb.
# Corpus data is high-entropy, so a healthy ratio is roughly 1-3x.
ratio="$(awk -v r="$raw" -v p="$packed" 'BEGIN { printf "%.2f", r / p }')"
if awk -v r="$ratio" 'BEGIN { exit !(r < 10) }'; then
    pass "ratio ${ratio}x"
else
    fail "ratio ${ratio}x is implausible for entropic corpus data"
fi

echo "== 5. executable content =="
# Corpus entries are opaque input bytes and must never be runnable. Matched
# narrowly on purpose: `file` collides constantly with short magic sequences in
# mutated data (PDP-11, Atari, AVR and friends are expected noise, not risks).
hits="$(find "$WORK" -type f -print0 | xargs -0 file 2>/dev/null \
    | grep -cE 'ELF |Mach-O|PE32|MS-DOS executable|shell script|Python script' || true)"
if [ "$hits" -eq 0 ]; then
    pass "no ELF/Mach-O/PE/script content"
else
    fail "$hits entries look executable -- inspect before publishing"
fi

echo "== 6. secrets and PII =="
found=0
for p in "${SECRET_PATTERNS[@]}" "${PATH_PATTERNS[@]}"; do
    # -e is required, not stylistic: patterns like -----BEGIN otherwise parse as
    # grep options, and grep's exit 2 propagates through pipefail and set -e,
    # killing the script before this check or the provenance one ever runs.
    # `|| true` is load-bearing: grep exits 1 when a pattern is absent, which is
    # the expected result here, and pipefail would otherwise turn every clean
    # sweep into an abort.
    n="$(grep -rlaE -e "$p" "$WORK" 2>/dev/null | wc -l || true)"
    if [ "$n" -ne 0 ]; then
        fail "pattern '$p' matched $n entrie(s)"
        found=1
    fi
done
if [ "$found" -eq 0 ]; then
    pass "no key material, credentials or local paths"
fi

echo "== 7. mainnet provenance =="
# Chain-derived corpora must contain genuinely mined blocks. A Zcash header is
# 1487 bytes (through the 1344-byte Equihash solution); its double-SHA256 must
# show leading zeros to satisfy proof-of-work. Random or fabricated bytes hit 8
# leading hex zeros at odds of ~2.3e-10 per entry, so a handful of hits is
# conclusive -- and cannot be forged without actually doing the work.
if command -v python3 >/dev/null; then
    # Guarded by if/else, not `$?` after the fact: under set -e a non-zero exit
    # from python3 would abort before any `[ $? ... ]` line could inspect it.
    if python3 - "$WORK" <<'PY'
import hashlib, os, sys
work = sys.argv[1]
HDR, THRESHOLD, SAMPLE = 1487, 8, 400
ok = True
for target in ("block_deserialize", "block_deep_fuzz"):
    d = os.path.join(work, f"{target}_seed_corpus")
    if not os.path.isdir(d):
        print(f"  \033[31mFAIL\033[0m {target}: extracted directory missing")
        ok = False
        continue
    files = [os.path.join(d, f) for f in os.listdir(d)]
    strong = 0
    for path in sorted(files, key=os.path.getsize, reverse=True)[:SAMPLE]:
        b = open(path, "rb").read()
        if len(b) < HDR:
            continue
        disp = hashlib.sha256(hashlib.sha256(b[:HDR]).digest()).digest()[::-1].hex()
        if len(disp) - len(disp.lstrip("0")) >= THRESHOLD:
            strong += 1
    if strong:
        print(f"  \033[32mok\033[0m   {target}: {strong} entries carry valid mainnet proof-of-work")
    else:
        print(f"  \033[31mFAIL\033[0m {target}: no entry satisfies PoW -- provenance unconfirmed")
        ok = False
sys.exit(0 if ok else 1)
PY
    then
        :
    else
        FAILURES=$((FAILURES + 1))
    fi
else
    skip "python3 not available; provenance unchecked"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$FAILURES check(s) failed"
fi
exit $((FAILURES > 0))
