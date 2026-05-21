#!/usr/bin/env bash
# =============================================================================
# check_translation_zip.sh
#
# Verifies that a return-translation zip file conforms to the Lingoport
# "One Zip per Locale" spec described at:
# https://wiki.lingoport.com/Zip_Files_For_Prep_and_Import
#
# Usage:
#   ./check_translation_zip.sh <zip-file> [expected-files...]
#
# Examples:
#   # Check structure only (no expected-file verification)
#   ./check_translation_zip.sh Queens.Champions.1.fr_fr.zip
#
#   # Also verify that specific files are present inside the zip
#   ./check_translation_zip.sh Queens.Champions.1.fr_fr.zip \
#       resources_en.properties messages.resx errors.json
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS="[PASS]"
FAIL="[FAIL]"
INFO="[INFO]"
WARN="[WARN]"

errors=0

pass()  { echo "  $PASS  $*"; }
fail()  { echo "  $FAIL  $*"; (( errors++ )) || true; }
info()  { echo "  $INFO  $*"; }
warn()  { echo "  $WARN  $*"; }
header(){ echo; echo "── $* ──"; }

require_cmd() {
    command -v "$1" &>/dev/null || { echo "ERROR: '$1' is required but not installed." >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_cmd unzip
require_cmd basename
require_cmd dirname

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <zip-file> [expected-file1 expected-file2 ...]" >&2
    exit 1
fi

ZIP_PATH="$1"
shift
EXPECTED_FILES=("$@")   # may be empty

echo "========================================================"
echo " Lingoport Return-Translation Zip Checker"
echo " File : $ZIP_PATH"
echo "========================================================"

# ---------------------------------------------------------------------------
# CHECK 1 – File exists and is readable
# ---------------------------------------------------------------------------
header "CHECK 1: File existence"
if [[ ! -f "$ZIP_PATH" ]]; then
    fail "File not found: $ZIP_PATH"
    echo; echo "Total errors: $errors — cannot continue without the file."
    exit 1
else
    pass "File exists: $ZIP_PATH"
fi

# ---------------------------------------------------------------------------
# CHECK 2 – File is a valid zip archive
# ---------------------------------------------------------------------------
header "CHECK 2: Valid zip archive"
if ! unzip -tq "$ZIP_PATH" &>/dev/null; then
    fail "File is not a valid zip archive (unzip -t failed)"
    echo; echo "Total errors: $errors — cannot continue with a corrupt archive."
    exit 1
else
    pass "Archive integrity OK"
fi

# ---------------------------------------------------------------------------
# CHECK 3 – Zip filename convention: <group>.<project>.<version>.<locale>.zip
#           locale uses underscores (never hyphens) as separator
# ---------------------------------------------------------------------------
header "CHECK 3: Zip filename convention"

BASENAME=$(basename "$ZIP_PATH")                        # e.g. Queens.Champions.1.fr_fr.zip
STEM="${BASENAME%.zip}"                                  # e.g. Queens.Champions.1.fr_fr

# Must end in .zip (case-sensitive per spec)
if [[ "$BASENAME" != *.zip ]]; then
    fail "Filename does not end with '.zip': $BASENAME"
else
    pass "Extension is '.zip'"
fi

# Split on dots – expect exactly 4 segments
IFS='.' read -ra PARTS <<< "$STEM"
if [[ ${#PARTS[@]} -lt 4 ]]; then
    fail "Filename has fewer than 4 dot-separated segments (expected <group>.<project>.<version>.<locale>): $STEM"
    GROUP=""; PROJECT=""; VERSION=""; LOCALE=""
else
    GROUP="${PARTS[0]}"
    PROJECT="${PARTS[1]}"
    VERSION="${PARTS[2]}"
    # Locale is everything after the third dot (handles locales like fr_FR that have no extra dots)
    LOCALE=$(printf '%s.' "${PARTS[@]:3}")   # rejoin any trailing parts with dots
    LOCALE="${LOCALE%.}"                     # strip trailing dot

    info "Parsed  group=$GROUP  project=$PROJECT  version=$VERSION  locale=$LOCALE"

    [[ -n "$GROUP"   ]] && pass "group-name present: $GROUP"   || fail "group-name segment is empty"
    [[ -n "$PROJECT" ]] && pass "project-name present: $PROJECT" || fail "project-name segment is empty"

    if [[ "$VERSION" =~ ^[0-9]+$ ]]; then
        pass "kit-version is numeric: $VERSION"
    else
        fail "kit-version should be numeric, got: '$VERSION'"
    fi

    if [[ -n "$LOCALE" ]]; then
        pass "locale segment present: $LOCALE"
    else
        fail "locale segment is empty"
    fi

    # Locale must use underscore, never hyphen
    if [[ "$LOCALE" == *-* ]]; then
        fail "locale uses hyphen instead of underscore: '$LOCALE' (spec requires underscore)"
    else
        pass "locale uses underscore separator (or is single-segment): $LOCALE"
    fi
fi

# ---------------------------------------------------------------------------
# CHECK 4 – Exactly one top-level directory inside the zip,
#           named identically to the stem of the zip filename
# ---------------------------------------------------------------------------
header "CHECK 4: Single top-level directory"

# Collect all entries from the zip listing
mapfile -t ALL_ENTRIES < <(unzip -Z1 "$ZIP_PATH" 2>/dev/null)

if [[ ${#ALL_ENTRIES[@]} -eq 0 ]]; then
    fail "Zip archive appears to be empty"
else
    info "Total entries in archive: ${#ALL_ENTRIES[@]}"
fi

# Top-level entries are those with no slash or only a trailing slash
# (i.e. the part before the first '/' is the top-level name)
declare -A TOP_LEVEL_DIRS
for entry in "${ALL_ENTRIES[@]}"; do
    top="${entry%%/*}"   # everything before the first slash
    if [[ -n "$top" ]]; then
        TOP_LEVEL_DIRS["$top"]=1
    fi
done

TLD_COUNT=${#TOP_LEVEL_DIRS[@]}
TLD_NAMES=("${!TOP_LEVEL_DIRS[@]}")

if [[ $TLD_COUNT -eq 0 ]]; then
    fail "Could not determine any top-level directory in the archive"
elif [[ $TLD_COUNT -gt 1 ]]; then
    fail "Archive contains $TLD_COUNT top-level entries; expected exactly 1. Found: ${TLD_NAMES[*]}"
else
    ACTUAL_TLD="${TLD_NAMES[0]}"
    pass "Exactly one top-level directory: $ACTUAL_TLD"

    # The top-level dir name must equal the zip stem
    if [[ -n "$STEM" && "$ACTUAL_TLD" == "$STEM" ]]; then
        pass "Top-level directory name matches zip stem: $STEM"
    else
        fail "Top-level directory '$ACTUAL_TLD' does not match expected '$STEM'"
    fi
fi

# ---------------------------------------------------------------------------
# CHECK 5 – No files sit at the root of the archive (outside the top-level dir)
# ---------------------------------------------------------------------------
header "CHECK 5: No loose files at archive root"

ROOT_FILES=()
for entry in "${ALL_ENTRIES[@]}"; do
    # A root-level file has no slash at all, or no slash before the last char
    if [[ "$entry" != */ && "$entry" != */* ]]; then
        ROOT_FILES+=("$entry")
    fi
done

if [[ ${#ROOT_FILES[@]} -gt 0 ]]; then
    fail "Found ${#ROOT_FILES[@]} file(s) at the archive root (outside the top-level directory):"
    for f in "${ROOT_FILES[@]}"; do
        echo "        $f"
    done
else
    pass "No loose files at archive root"
fi

# ---------------------------------------------------------------------------
# CHECK 6 – All files are directly under the single top-level directory
#           (no unexpected nested sub-directories required by spec)
# ---------------------------------------------------------------------------
header "CHECK 6: Files reside inside top-level directory"

if [[ -n "${ACTUAL_TLD:-}" ]]; then
    OUTSIDE=()
    for entry in "${ALL_ENTRIES[@]}"; do
        # Skip the top-level directory entry itself
        [[ "$entry" == "${ACTUAL_TLD}/" || "$entry" == "$ACTUAL_TLD" ]] && continue
        if [[ "$entry" != "${ACTUAL_TLD}/"* ]]; then
            OUTSIDE+=("$entry")
        fi
    done

    if [[ ${#OUTSIDE[@]} -gt 0 ]]; then
        fail "Found ${#OUTSIDE[@]} entry/entries outside the top-level directory:"
        for f in "${OUTSIDE[@]}"; do
            echo "        $f"
        done
    else
        pass "All entries are under '$ACTUAL_TLD/'"
    fi
else
    warn "Skipped (top-level directory could not be determined)"
fi

# ---------------------------------------------------------------------------
# CHECK 7 – Archive contains at least one translateable file
# ---------------------------------------------------------------------------
header "CHECK 7: Archive is non-empty (contains files)"

PAYLOAD_FILES=()
for entry in "${ALL_ENTRIES[@]}"; do
    # Not a directory, not the TLD itself
    if [[ "$entry" != */ ]]; then
        PAYLOAD_FILES+=("$entry")
    fi
done

if [[ ${#PAYLOAD_FILES[@]} -eq 0 ]]; then
    fail "Archive contains no files (only directories or is empty)"
else
    pass "Archive contains ${#PAYLOAD_FILES[@]} file(s)"
    for f in "${PAYLOAD_FILES[@]}"; do
        info "  $f"
    done
fi

# ---------------------------------------------------------------------------
# CHECK 8 – Expected files are present (only if caller supplied a list)
# ---------------------------------------------------------------------------
if [[ ${#EXPECTED_FILES[@]} -gt 0 ]]; then
    header "CHECK 8: Expected files present"

    for expected in "${EXPECTED_FILES[@]}"; do
        FOUND=0
        for entry in "${PAYLOAD_FILES[@]}"; do
            if [[ "$(basename "$entry")" == "$expected" ]]; then
                FOUND=1
                break
            fi
        done
        if [[ $FOUND -eq 1 ]]; then
            pass "Found expected file: $expected"
        else
            fail "Missing expected file: $expected"
        fi
    done
else
    info "No expected-files list supplied; skipping CHECK 8"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "========================================================"
if [[ $errors -eq 0 ]]; then
    echo " RESULT: ALL CHECKS PASSED"
else
    echo " RESULT: $errors CHECK(S) FAILED"
fi
echo "========================================================"
echo

exit $(( errors > 0 ? 1 : 0 ))
