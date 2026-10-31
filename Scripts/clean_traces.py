#!/usr/bin/env python3
"""Prepares GeoJSON traces for ALSOMAPS_TRACES.

cesium-native rejects a whole document over one line with fewer than two
points, which Strava exports have. This drops those lines, and any feature
left with none.

    clean_traces.py traces.geojson clean.geojson
    clean_traces.py traces.geojson clean.geojson --near 42.39 -71.12 0.5

--near keeps only the trips whose middle point is within that many degrees of
a latitude and longitude.
"""

import argparse
import json


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('input')
    parser.add_argument('output')
    parser.add_argument('--near', nargs=3, type=float, metavar=('LAT', 'LON', 'DEGREES'))
    args = parser.parse_args()

    with open(args.input) as f:
        document = json.load(f)

    dropped = 0
    features = []
    for feature in document['features']:
        lines = feature['geometry']['coordinates']
        kept = [line for line in lines if len(line) >= 2]
        dropped += len(lines) - len(kept)
        if not kept:
            continue
        if args.near:
            lat, lon, degrees = args.near
            x, y = kept[0][len(kept[0]) // 2][:2]
            if abs(y - lat) > degrees or abs(x - lon) > degrees:
                continue
        feature['geometry']['coordinates'] = kept
        features.append(feature)

    with open(args.output, 'w') as f:
        json.dump({'type': 'FeatureCollection', 'features': features}, f)
    vertices = sum(len(line) for feature in features for line in feature['geometry']['coordinates'])
    print(f'{len(features)} features, {vertices} vertices; dropped {dropped} short lines')


if __name__ == '__main__':
    main()
