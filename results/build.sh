#!/usr/bin/env bash

set -eu

ROOT_DIR="$(dirname "$(readlink -f "$0")")"
BUILD_DIR="${ROOT_DIR}/build"
PARTY=""

if [[ "$#" -ne 1 ]]; then
    >&2 echo "error: required 1 argument: PARTY (available options: prover, verifier)"
    exit 1
fi

case "$1" in
    "prover" | "verifier")
        PARTY="$1"
        ;;
    *)
        >&2 echo "error: unknown party: \"$1\" (available options: prover, verifier)"
        exit 1
        ;;
esac

LATEXMK=(
    "latexmk"
    "--cd"
    "--lualatex"
    "--outdir=${BUILD_DIR}"
    "--auxdir=${BUILD_DIR}"
    "${ROOT_DIR}/${PARTY}.tex"
)
"${LATEXMK[@]}"

MAGICK_JPG=(
    "magick"
    "-density" "600"
    "${BUILD_DIR}/${PARTY}.pdf"
    "${BUILD_DIR}/${PARTY}.jpg"
)
"${MAGICK_JPG[@]}"
