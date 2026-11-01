#!/bin/sh
# SPDX-FileCopyrightText: 2026 yukunlabs
# SPDX-License-Identifier: 0BSD
# Refs: US-28, AC-28.02, AC-28.04.
# Renders the product film frame by frame from Lunlet's real views with synthetic data (ProductFilmRenderTests), then
# encodes the MP4, poster and captions in website/video. Nothing is recorded from the screen.
# Usage: scripts/render-film.sh [new-frames-directory]   (frames are kept only when a directory is given)
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

ffmpeg_bin=$(command -v ffmpeg || true)
if [ -z "$ffmpeg_bin" ] && [ -x /opt/homebrew/bin/ffmpeg ]; then
    ffmpeg_bin=/opt/homebrew/bin/ffmpeg
fi
if [ -z "$ffmpeg_bin" ]; then
    echo "render-film: FFmpeg is required (for example, brew install ffmpeg)" >&2
    exit 1
fi

if [ $# -gt 0 ]; then
    frames=$1
    if [ -e "$frames" ] && [ -n "$(ls -A "$frames")" ]; then
        echo "render-film: $frames must be a new or empty directory" >&2
        exit 1
    fi
    mkdir -p "$frames"
else
    frames=$(mktemp -d "${TMPDIR:-/tmp}/lunlet-film.XXXXXX")
    trap 'rm -rf "$frames"' EXIT
fi

LUNLET_FILM_DIR="$frames" scripts/test-core.sh --filter ProductFilmRenderTests
if [ ! -f "$frames/frame-00001.png" ] || [ ! -f "$frames/poster.png" ]; then
    echo "render-film: the film test rendered no frames" >&2
    exit 1
fi

out=website/video
# sRGB frames become BT.709 4:2:0 H.264, tagged so players keep the colors, with adaptive quantization that keeps dark
# gradients smooth; silent and streamable from the start. CRF 19 keeps the minute-long film under about 8 MB while the
# whole-display text stays sharp.
"$ffmpeg_bin" -hide_banner -loglevel error -y -framerate 30 -i "$frames/frame-%05d.png" \
    -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" \
    -c:v libx264 -preset slow -crf 19 -x264-params aq-mode=3 \
    -movflags +faststart -an "$out/lunlet-walkthrough.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -y -i "$frames/poster.png" -q:v 3 "$out/lunlet-poster.jpg"
cp "$frames/lunlet-captions.vtt" "$out/lunlet-captions.vtt"
# The film's manifest records the sources it was drawn from, so scripts/check_site_assets.py can tell when it lags them.
python3 scripts/check_site_assets.py --film --write
ls -l "$out/lunlet-walkthrough.mp4" "$out/lunlet-poster.jpg" "$out/lunlet-captions.vtt"
