#!/usr/bin/env python3
"""Extract a single-floor navigation model from PLY vertex centers."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import struct

TYPES = {
    "char": "b", "int8": "b", "uchar": "B", "uint8": "B",
    "short": "h", "int16": "h", "ushort": "H", "uint16": "H",
    "int": "i", "int32": "i", "uint": "I", "uint32": "I",
    "float": "f", "float32": "f", "double": "d", "float64": "d",
}


def vertices(source, min_opacity):
    if source.readline().strip() != b"ply":
        raise ValueError("Expected a PLY file.")
    encoding = None
    vertex_count = None
    columns = []
    element = None
    for raw in source:
        fields = raw.decode("ascii").split()
        if not fields:
            continue
        match fields:
            case ["format", kind, "1.0"]:
                encoding = kind
            case ["element", name, count]:
                if vertex_count is None and name != "vertex" and int(count):
                    raise ValueError("The vertex element must come first.")
                element = name
                if name == "vertex":
                    vertex_count = int(count)
            case ["property", scalar, name] if element == "vertex":
                columns.append((scalar, name))
            case ["property", *_] if element == "vertex":
                raise ValueError("Variable-length vertex properties are unsupported.")
            case ["end_header"]:
                break
    if not vertex_count or vertex_count < 0:
        raise ValueError("No vertices in PLY.")
    names = [name for _, name in columns]
    xyz = [names.index(axis) for axis in "xyz"]
    gaussian = "opacity" in names and all(f"scale_{axis}" in names for axis in range(3))
    opacity = names.index("opacity") if gaussian else None
    logit = math.log(min_opacity / (1 - min_opacity))

    def point(row):
        if opacity is None or float(row[opacity]) >= logit:
            return tuple(float(row[index]) for index in xyz)
        return None
    if encoding == "ascii":
        for _ in range(vertex_count):
            row = source.readline().split()
            if len(row) != len(columns):
                raise ValueError("Truncated or invalid ASCII vertex row.")
            if (xyz_point := point(row)) is not None:
                yield xyz_point
    elif encoding in {"binary_little_endian", "binary_big_endian"}:
        order = "<" if encoding == "binary_little_endian" else ">"
        layout = struct.Struct(order + "".join(TYPES[kind] for kind, _ in columns))
        for offset in range(0, vertex_count, 8192):
            size = min(8192, vertex_count - offset) * layout.size
            batch = source.read(size)
            if len(batch) != size:
                raise ValueError("Truncated binary vertices.")
            for row in layout.iter_unpack(batch):
                if (xyz_point := point(row)) is not None:
                    yield xyz_point
    else:
        raise ValueError(f"Unsupported PLY encoding: {encoding}.")


def neighbors(cell):
    x, z = cell
    return ((x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1))


def components(cells):
    unseen = set(cells)
    for seed in sorted(unseen):
        if seed not in unseen:
            continue
        unseen.remove(seed)
        group = {seed}
        frontier = [seed]
        while frontier:
            for neighbor in neighbors(frontier.pop()):
                if neighbor in unseen:
                    unseen.remove(neighbor)
                    group.add(neighbor)
                    frontier.append(neighbor)
        yield group


def extract(args):
    up = "xyz".index(args.up[-1])
    side, forward = [axis for axis in range(3) if axis != up]
    sign = -1 if args.up.startswith("-") else 1
    floor_hits = Counter()
    obstacle_hits = Counter()
    heights = {}
    with args.source.open("rb") as source:
        for point in vertices(source, args.min_opacity):
            if not all(map(math.isfinite, point)):
                continue
            y = sign * point[up] * args.scale - args.floor
            if not -args.floor_band <= y <= args.clearance:
                continue
            cell = tuple(math.floor(point[axis] * args.scale / args.cell) for axis in (side, forward))
            if abs(y) <= args.floor_band:
                floor_hits[cell] += 1
            elif y >= args.obstacle_min:
                obstacle_hits[cell] += 1
                heights[cell] = max(heights.get(cell, 0), y)

    floor = {cell for cell, count in floor_hits.items() if count >= args.min_points}
    obstacles = {cell for cell, count in obstacle_hits.items() if count >= args.min_points}
    walkable = floor - obstacles
    if not walkable:
        raise ValueError("No walkable cells. Check floor elevation, axis, scale and point threshold.")
    if args.start is None:
        reachable = max(components(walkable), key=len)
        start = min(reachable)
    else:
        start = tuple(args.start)
        if start not in walkable:
            raise ValueError("--start is outside observed walkable floor.")
        reachable = next(group for group in components(walkable) if start in group)

    cells = floor | obstacles
    left, back = map(min, zip(*cells))
    right, front = map(max, zip(*cells))
    width, depth = right - left + 1, front - back + 1
    if width * depth > 60_000:
        raise ValueError("Grid exceeds 60,000 cells. Increase --cell or crop the source.")

    def local(cell):
        return cell[0] - left, cell[1] - back

    objects = []
    for number, group in enumerate(components(obstacles), 1):
        x, z = map(min, zip(*group))
        max_x, max_z = map(max, zip(*group))
        adjacent = sorted({other for cell in group for other in neighbors(cell) if other in reachable})
        # Compact components are review candidates, not equipment classifications.
        candidate = bool(adjacent) and 2 <= len(group) <= 25
        obj = {
            "name": f"Unclassified cluster {number}",
            "x": x - left,
            "z": z - back,
            "width": max_x - x + 1,
            "depth": max_z - z + 1,
            "height": round(max(heights[cell] for cell in group), 2),
            "cells": [local(cell) for cell in sorted(group)],
        }
        if candidate:
            obj["service"] = local(min(adjacent, key=lambda cell: (abs(cell[0] - start[0]) + abs(cell[1] - start[1]), cell)))
        objects.append(obj)

    return {
        "name": f"{args.source.stem} · PLY geometry",
        "width": width,
        "depth": depth,
        "cellSize": args.cell,
        "originMetres": [left * args.cell, back * args.cell],
        "start": local(start),
        "floor": [local(cell) for cell in sorted(walkable)],
        "objects": objects,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--up", default="y", choices=["x", "y", "z", "-x", "-y", "-z"])
    parser.add_argument("--floor", type=float, required=True, help="Floor elevation in metres along signed up axis")
    parser.add_argument("--scale", type=float, default=1.0, help="Metres per PLY unit")
    parser.add_argument("--cell", type=float, default=0.4, help="Grid cell width in metres")
    parser.add_argument("--floor-band", type=float, default=0.10)
    parser.add_argument("--obstacle-min", type=float, default=0.15)
    parser.add_argument("--clearance", type=float, default=2.0)
    parser.add_argument("--min-opacity", type=float, default=0.1, help="Minimum 3DGS opacity after sigmoid")
    parser.add_argument("--min-points", type=int, default=2)
    parser.add_argument("--start", type=int, nargs=2, help="Start grid coordinates before shifting by originMetres")
    args = parser.parse_args()
    if not (args.cell > 0 and args.scale > 0 and 0 < args.floor_band < args.obstacle_min < args.clearance and args.min_points > 0 and 0 < args.min_opacity < 1):
        parser.error("Check cell size, scale, height thresholds and minimum point count.")
    try:
        model = extract(args)
        args.output.write_text(json.dumps(model, indent=2) + "\n", encoding="utf-8")
    except (OSError, UnicodeError, ValueError, KeyError, OverflowError) as error:
        parser.exit(1, f"PLY import failed: {error}\n")
    print(f"{len(model['floor'])} walkable cells, {len(model['objects'])} obstacle clusters.")


if __name__ == "__main__":
    main()
