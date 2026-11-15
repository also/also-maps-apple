#!/bin/sh
# Writes Geography.sqlite to <output>, building it from the Natural Earth files
# pinned in Scripts/natural_earth.txt with Tools/GeographyBuilder.
#
# Runs as a build phase of the visionOS, iOS and macOS apps and Core Tests, and
# works by hand too. Downloads and results are cached in
# ~/Library/Caches/dev.also.maps/geography (or $ALSOMAPS_GEOGRAPHY_CACHE): a
# build only downloads and converts when the pinned files or the converter's
# source change, which takes a few seconds. Otherwise it copies the cached file.
#
# usage: Scripts/build_geography.sh <output>
set -eu

if [ $# -ne 1 ]; then
  echo "usage: $0 <output>" >&2
  exit 2
fi
output="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
sources="$root/Scripts/natural_earth.txt"
cache="${ALSOMAPS_GEOGRAPHY_CACHE:-$HOME/Library/Caches/dev.also.maps/geography}"
mkdir -p "$cache/downloads" "$cache/builds"

# Everything the result depends on.
key="$(cat "$sources" "$root/Sources/Geography/GeographyDatabase.swift" "$root"/Tools/GeographyBuilder/*.swift |
  shasum -a 256 | cut -c1-16)"
built="$cache/builds/$key.sqlite"

if [ ! -f "$built" ]; then
  work="$(mktemp -d "$cache/work.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  bases="$(awk '$1 == "base" { print $2 }' "$sources")"
  tolerance="$(awk '$1 == "tolerance" { print $2 }' "$sources")"

  awk '$1 == "file" { print $2, $3, $4 }' "$sources" | while read -r name path sha; do
    zip="$cache/downloads/$sha.zip"
    if [ ! -f "$zip" ]; then
      fetched=""
      for base in $bases; do
        if curl -fsSL --retry 2 -A "geography-build" -o "$work/download" "$base/$path" &&
           [ "$(shasum -a 256 "$work/download" | cut -d ' ' -f 1)" = "$sha" ]; then
          mv "$work/download" "$zip"
          fetched=1
          break
        fi
        echo "warning: $base/$path didn't download, or its SHA-256 isn't the pinned one" >&2
      done
      if [ -z "$fetched" ]; then
        echo "error: no source in Scripts/natural_earth.txt serves $path with SHA-256 $sha" >&2
        exit 1
      fi
    fi
    mkdir -p "$work/$name"
    unzip -q -o "$zip" -d "$work/$name"
  done

  # The converter runs on this Mac, whatever platform the app build targets,
  # so it's compiled without the build's SDK and deployment settings.
  sdk="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
  env -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET xcrun --sdk macosx swiftc -O \
    -sdk "$sdk" -target "$(uname -m)-apple-macos14" \
    -module-cache-path "$work/module-cache" \
    -o "$work/GeographyBuilder" \
    "$root/Sources/Geography/GeographyDatabase.swift" \
    "$root"/Tools/GeographyBuilder/*.swift

  "$work/GeographyBuilder" \
    --places "$work/places/ne_10m_populated_places" \
    --admin1 "$work/admin1/ne_10m_admin_1_states_provinces" \
    --marine "$work/marine/ne_10m_geography_marine_polys" \
    --tolerance "$tolerance" \
    --output "$work/Geography.sqlite"
  mv "$work/Geography.sqlite" "$built"

  # Keep the few most recent results, for switching between branches.
  ls -t "$cache/builds"/*.sqlite | tail -n +6 | while read -r old; do rm -f "$old"; done
fi

mkdir -p "$(dirname "$output")"
cmp -s "$built" "$output" || cp -f "$built" "$output"
