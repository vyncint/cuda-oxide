#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Reject a prose reference to a source file that no longer exists.
#
# #1190 split several large files into module directories, and three places in
# the tree kept pointing at the paths it removed -- a test's module doc at
# `crates/mir-lower/src/convert/types.rs`, two example READMEs at
# `crates/mir-importer/src/translator/rvalue.rs`. #1197 repointed those, and 14
# more in other spellings. Nothing had noticed: a path in prose is compiled by
# nothing, `check-host-api-paths.sh` checks Rust *API* paths rather than files,
# and the book gate only builds. The reference just goes quiet, and a reader
# follows it into nothing.
#
# Scope, deliberately narrow, because this is the kind of guard that goes soft
# the moment it needs an exemption list:
#
#   * A path is only checked when it is anchored at a repo root -- crates/,
#     cuda-oxide-book/, scripts/, docs/ -- and carries a file extension. That
#     is the spelling a new reference normally takes, and the only one that is
#     unambiguous on its own.
#   * A path whose parent directory holds no tracked file at all is skipped:
#     that is a generated output location, not a claim about the tree.
#     `crates/fuzzer/README.md` documents `crates/fuzzer/artifacts/summary.jsonl`,
#     which `run_seed.py` writes and clears on every run, and the sentence is
#     correct. Requiring the *parent* to be tracked keeps that quiet without an
#     exemption entry, and still catches a file removed from a directory that
#     otherwise survives -- which is every case #1197 was filed for.
#   * Prose only: every line of a tracked *.md, and `///` or `//!` lines in a
#     tracked *.rs. This is what removes the need for an allowlist. The
#     non-existent paths that live in Rust *code* are all deliberate --
#     synthetic fixture names (`intrinsics/probes/removed.ll`,
#     `intrinsics/overlay/test.toml`), two paths that cuda-intrinsics-gen
#     render tests assert are *absent*, and the mktemp canary in
#     check-reserved-prefixes.sh -- and none of them is prose, so none of them
#     needs an entry here.
#
# Two things are out of scope on purpose:
#
#   * `intrinsics/` is not a root. It is both a real top-level directory and a
#     common crate-relative fragment: examples/atomics/README.md names
#     `intrinsics/atomic.rs` in a pipeline diagram, meaning
#     `mir-importer/src/translator/terminator/intrinsics/atomic.rs`, which is
#     correct as shorthand. Rooting there would fail that line.
#   * Crate-relative (`mir-lower/src/convert/types.rs`) and bare-basename
#     ("the walker in `rvalue.rs`") spellings are not checked. #1197's
#     follow-up fixed 14 references written that way, so this is a real gap and
#     is stated rather than papered over -- telling `rvalue.rs` in prose from
#     any other mention of it is guesswork, and a guard that guesses is worse
#     than one that is narrow.
#
# Measured on 26754ae5: 72 paths checked, 0 broken. Run against 6f5f538a^, the
# commit before #1197 landed, it reports exactly the three references that PR
# was filed for.
set -euo pipefail

export LC_ALL=C

cd "$(dirname "$0")/.."

ROOTS='crates|cuda-oxide-book|scripts|docs'
EXTS='rs|md|sh|toml|jsonl|json|ll|py|yaml|yml'
# The trailing \b matters: without it `.json` matches inside `.jsonl` and the
# guard reports a path nobody wrote. Longer alternatives lead for the same
# reason.
PATTERN="(${ROOTS})/[A-Za-z0-9._/-]+\.(${EXTS})\\b"

# `grep -n` keeps the line number; the *.rs arm narrows to doc comments first
# so a path mentioned in code is never read as a claim about the tree.
prose_lines() {
    case "$1" in
    *.md) grep -nE "${PATTERN}" -- "$1" 2>/dev/null || true ;;
    *.rs) grep -nE '^[[:space:]]*(///|//!)' -- "$1" 2>/dev/null |
        grep -E "${PATTERN}" || true ;;
    esac
}

# The one scanner. The self-test below runs *this*, not a paraphrase of it, so
# disabling any step -- the pattern, the tracked-parent skip, the existence
# test -- fails the self-test instead of quietly reporting a clean tree.
broken_in_file() {
    local file="$1" hit lineno path parent
    while IFS= read -r hit; do
        [ -n "${hit}" ] || continue
        lineno="${hit%%:*}"
        while IFS= read -r path; do
            [ -n "${path}" ] || continue
            # A directory with no tracked file under it is an output
            # location; the path is not claiming to be in the tree.
            parent="${path%/*}"
            if [ -z "$(git ls-files -- "${parent}" | head -n 1)" ]; then
                continue
            fi
            if [ ! -e "${path}" ]; then
                printf '%s:%s: names %s, which does not exist\n' \
                    "${file}" "${lineno}" "${path}"
            fi
        done < <(printf '%s\n' "${hit#*:}" | grep -oE "${PATTERN}" | sort -u)
    done < <(prose_lines "${file}")
}

# Self-test. The failure mode this guard has to survive is "silently stops
# reporting", so run the real scanner over one prose line naming a path that
# cannot exist inside a directory the repo does track, and one naming a file
# that does, and require exactly one hit and the right one. A dead path under
# an untracked directory would be skipped by design, so the canary puts it
# somewhere tracked -- otherwise the self-test would pass for the wrong reason.
canary="$(mktemp -d)"
trap 'rm -rf "${canary}"' EXIT
printf 'prose naming crates/cuda-device/src/no-such-file-%s.rs inline\n' "$$" \
    >"${canary}/dead.md"
printf 'prose naming scripts/check-source-references.sh inline\n' \
    >"${canary}/live.md"
dead_hits="$(broken_in_file "${canary}/dead.md" | wc -l)"
live_hits="$(broken_in_file "${canary}/live.md" | wc -l)"
if [ "${dead_hits}" -ne 1 ] || [ "${live_hits}" -ne 0 ]; then
    echo "error: source-reference guard self-test failed: the scanner found" >&2
    echo "       ${dead_hits} problem(s) in a file with exactly one dead path" >&2
    echo "       and ${live_hits} in a file with none, so a clean result on the" >&2
    echo "       tree means nothing" >&2
    exit 1
fi

checked=0
broken=0
while IFS= read -r file; do
    while IFS= read -r problem; do
        [ -n "${problem}" ] || continue
        printf '%s\n' "${problem}" >&2
        broken=$((broken + 1))
    done < <(broken_in_file "${file}")
    while IFS= read -r _path; do
        [ -n "${_path}" ] || continue
        checked=$((checked + 1))
    done < <(prose_lines "${file}" | grep -oE "${PATTERN}" | sort -u)
done < <(git ls-files -- '*.md' '*.rs')

if [ "${broken}" -ne 0 ]; then
    echo "" >&2
    echo "error: ${broken} prose reference(s) point at a path that is not in" >&2
    echo "       the tree. Repoint each one at where the code lives now; if" >&2
    echo "       the surrounding sentence describes the old shape, it needs" >&2
    echo "       rewriting too, not just a new path." >&2
    exit 1
fi

echo "source references ok: ${checked} repo-anchored paths in prose, all resolve"
