# zebra-fuzz-corpora

[![verify](https://github.com/ZcashFoundation/zebra-fuzz-corpora/actions/workflows/verify.yml/badge.svg)](https://github.com/ZcashFoundation/zebra-fuzz-corpora/actions/workflows/verify.yml)

Seed corpora for the [Zebra](https://github.com/ZcashFoundation/zebra) `cargo-fuzz` harnesses.

The harnesses themselves live in Zebra at [`zebra-fuzz/`](https://github.com/ZcashFoundation/zebra/tree/main/zebra-fuzz),
versioned alongside the code they exercise. Only the binary seed corpora live here, so that ~17 MB
of opaque compressed archives stay out of the consensus node's git history.

## Contents

```
seeds/<target>_seed_corpus.zip     one archive per fuzz target, 15 total
SHA256SUMS                         checksums for the above
verify.sh                          integrity + safety audit, see Verifying
```

The filenames are a contract, not a convention: OSS-Fuzz's `build.sh` looks each archive up by fuzz
target name, and [OSS-Fuzz expects](https://google.github.io/oss-fuzz/getting-started/new-project-guide/)
a `<fuzz_target>_seed_corpus.zip` next to the target binary in `$OUT`. Renaming an archive silently
removes that target's seeds. Adding a fuzz target to Zebra without adding a matching archive here
will fail the OSS-Fuzz build, which is deliberate — the previous silent-skip behaviour meant a
target could run seedless without anyone noticing.

## How these are used

**OSS-Fuzz** ([google/oss-fuzz `projects/zebra`](https://github.com/google/oss-fuzz/tree/master/projects/zebra))
clones this repo alongside Zebra and copies each archive into `$OUT`:

```dockerfile
RUN git clone --depth 1 https://github.com/ZcashFoundation/zebra $SRC/zebra
RUN git clone --depth 1 https://github.com/ZcashFoundation/zebra-fuzz-corpora $SRC/corpora
```

`--depth 1` keeps that clone cheap no matter how this repo's history grows.

**Locally**, to run a Zebra fuzz target against its seeds:

```sh
git clone --depth 1 https://github.com/ZcashFoundation/zebra-fuzz-corpora
mkdir -p zebra/zebra-fuzz/fuzz/corpus/<target>
unzip -o zebra-fuzz-corpora/seeds/<target>_seed_corpus.zip \
      -d zebra/zebra-fuzz/fuzz/corpus/<target>
cd zebra && cargo +nightly fuzz run --fuzz-dir zebra-fuzz/fuzz <target>
```

`cargo fuzz` writes its evolving corpus back to `zebra-fuzz/fuzz/corpus/<target>/`, which is
git-ignored in Zebra. The archives here are a starting point, never a destination.

## Provenance

Everything in these archives derives from public Zcash mainnet chain data.

They were produced by minimising raw collected corpora with `cargo fuzz cmin` — libFuzzer's
`-merge=1`, a greedy pass that keeps an input only when it contributes a coverage feature the
earlier inputs did not. The result retains every coverage feature of what went in, though not
necessarily in the fewest possible files. Minimisation reduced 68,645 files (110 MB) to 14,648
files (24 MB) uncompressed, packed here as 15 archives totalling 16.67 MiB.

The v6 / Ironwood seeds were additionally seeded by `zebra-fuzz/fuzz/seed_gen.rs` in Zebra, which
constructs wire-valid v6 transactions spanning the bundle-presence / flag / value-balance / action-
count space. Zebra's `Arbitrary for Transaction` only produces v4/v5, so a fuzzer starting from
v4/v5 seeds almost never reaches a well-formed v6 structure by chance.

Imported from [ZcashFoundation/zebra#11221](https://github.com/ZcashFoundation/zebra/pull/11221)
at commit `eb8eced5d` (PR head `5059c77b9`), byte-for-byte — nothing was regenerated, reminimised
or trimmed. Per-archive checksums are in [`SHA256SUMS`](SHA256SUMS).

## Verifying

```sh
./verify.sh          # no network, a few seconds, exit 0 = all clear
```

Run it **after any refresh and before publishing anything here** — these archives are served to
OSS-Fuzz under the Foundation's name.

It checks the archive manifest against the 15 fuzz target names, the checksums in `SHA256SUMS`, the
decompression ratio (zip bomb), the absence of executable content and of secrets, credentials or
local paths, and mainnet provenance: a Zcash header is 1487 bytes through the Equihash solution, and
its double-SHA256 must show leading zeros to satisfy proof-of-work. Fabricated bytes clear 8 leading
hex zeros at odds of ~2.3e-10 each, so a handful of hits proves these are genuinely mined mainnet
blocks — the one property here that cannot be faked without doing the work.

Every check reports independently; a failure never stops the rest of the run.

CI runs the same script on every push and pull request
([`.github/workflows/verify.yml`](.github/workflows/verify.yml)), so a refresh cannot land unaudited —
but run it locally first, because the point is to catch a bad archive before it is published, not
after.

## Refreshing

These are a one-time bootstrap. Once OSS-Fuzz is running it maintains its own corpus per target in
Google Cloud Storage — synthesised continuously, minimised, and backed up daily — and that becomes
the living corpus. Anyone on the project's `auto_ccs` can download it from the ClusterFuzz fuzzer
statistics page. Expect the archives here to matter for the first weeks of a target's life and
little thereafter.

When a refresh is needed (eg to support network upgrades, etc.), replace the archive, regenerate the
checksums with `(cd seeds && sha256sum *.zip > ../SHA256SUMS)`, and run `./verify.sh` before
publishing. Note that `cmin` reshuffles which inputs survive, so a refresh tends to rewrite most of an
archive rather than append to it; already-compressed zips do not delta-compress, so each refresh
costs close to its full size in this repo's pack. That is the accepted trade for keeping them out of
Zebra. If refreshes ever become routine rather than exceptional, move the archives to release
assets, which can be pruned.

## License

MIT ([`LICENSE-MIT`](LICENSE-MIT)) OR Apache-2.0 ([`LICENSE-APACHE`](LICENSE-APACHE)), matching Zebra.
