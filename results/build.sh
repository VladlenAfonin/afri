#!/usr/bin/env bash

set -eu

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
BUILD_DIR="${SCRIPT_DIR}/build"
PARTY=""
PROTOCOL=""

if [[ "$#" -ne 2 ]]; then
    >&2 echo "error: required 2 arguments: PARTY (available options: prover, verifier) and PROTOCOL (available options: fri, stark)"
    exit 1
fi

case "$1" in
    "fri" | "stark")
        PROTOCOL="$1"
        ;;
    *)
        >&2 echo "error: unknown protocol: \"$1\" (available options: fri, stark)"
        exit 1
        ;;
esac

case "$2" in
    "prover" | "verifier")
        PARTY="$2"
        ;;
    *)
        >&2 echo "error: unknown party: \"$2\" (available options: prover, verifier)"
        exit 1
        ;;
esac

LATEXMK=(
    "latexmk"
    "--cd"
    "--lualatex"
    "--outdir=${BUILD_DIR}"
    "--auxdir=${BUILD_DIR}"
    "${SCRIPT_DIR}/${PROTOCOL}-${PARTY}.tex"
)
"${LATEXMK[@]}"

MAGICK_JPG=(
    "magick"
    "-density" "600"
    "${BUILD_DIR}/${PROTOCOL}-${PARTY}.pdf"
    "${BUILD_DIR}/${PROTOCOL}-${PARTY}.jpg"
)
"${MAGICK_JPG[@]}"
