#!/usr/bin/env python3
"""Animate registered scan points and reviewed catalog memberships on macOS."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


WIDTH, HEIGHT, FPS = 1920, 1080, 24
CUT_HEIGHT = 1.35
EYE = np.array([5.8, 18., 10.4])
LOOK_AT = np.array([6.5, .15, 5.6])
ROOM_X = (1.7163, 11.2871)
ROOM_Z = (1.5921, 9.5678)
EDGES = [(i, i | axis) for axis in (1, 4, 2) for i in range(8) if not i & axis]
START_SWEEP, END_SWEEP = 1.05, 13.8
TRACK_END = 14.35
DURATION = 18


def wave_time(x):
    return START_SWEEP + (END_SWEEP - START_SWEEP) * (x - ROOM_X[0]) / (ROOM_X[1] - ROOM_X[0])


def camera_at(time):
    time = min(time, TRACK_END)
    descent = np.clip((time - .75) / 3.45, 0, 1)
    descent = float(descent * descent * (3 - 2 * descent))
    progress = np.clip((time - START_SWEEP) / (END_SWEEP - START_SWEEP), 0, 1)
    focus_x = float(3.8 + (9.15 - 3.8) * progress)
    eye = (1 - descent) * EYE + descent * np.array([focus_x, 3.8, 9.05])
    look_at = (1 - descent) * LOOK_AT + descent * np.array([focus_x, .55, 5.8])
    return eye, look_at, 8.5 - 2.0 * descent


def projector(camera):
    eye, look_at, span = camera
    forward = look_at - eye
    forward /= np.linalg.norm(forward)
    right = np.cross(forward, [0, 1, 0])
    right /= np.linalg.norm(right)
    up = np.cross(right, forward)
    matrix = (HEIGHT / span * np.stack((right, -up), axis=1)).astype(np.float32)
    offset = np.array([WIDTH / 2, HEIGHT / 2], dtype=np.float32) - look_at.astype(np.float32) @ matrix
    return lambda points: points @ matrix + offset


def source_nodes(splats):
    xyz = splats[:, :3]
    inside = ((splats[:, 3] >= .12) & (xyz[:, 1] >= -.10) & (xyz[:, 1] <= CUT_HEIGHT)
              & (xyz[:, 0] >= ROOM_X[0]) & (xyz[:, 0] <= ROOM_X[1])
              & (xyz[:, 2] >= ROOM_Z[0]) & (xyz[:, 2] <= ROOM_Z[1]))
    points = xyz[inside]
    pixels = np.rint(projector(camera_at(0))(points)).astype(np.int32)
    visible = ((pixels[:, 0] >= 0) & (pixels[:, 0] < WIDTH)
               & (pixels[:, 1] >= 0) & (pixels[:, 1] < HEIGHT))
    pixels = pixels[visible]
    # Keep one observed centre per screen tile. Opacity breaks collisions.
    tile = pixels[:, 0] // 6 + (WIDTH // 6) * (pixels[:, 1] // 6)
    order = np.lexsort((-splats[inside, 3][visible], tile))
    _, first = np.unique(tile[order], return_index=True)
    return points[visible][order[first]]


def groups_for(site, membership, splats):
    groups = []
    for obj in site["objects"]:
        bounds = np.asarray(obj["extractionBounds"], dtype=np.float32)
        corners = np.array([[bounds[(i >> axis) & 1][axis] for axis in range(3)]
                            for i in range(8)])
        members = membership[obj["objectId"]]
        if not len(members) or members.min() < 0 or members.max() >= len(splats):
            raise ValueError(f"Invalid source membership for {obj['objectId']}")
        points = splats[members, :3]
        times = wave_time(points[:, 0])
        groups.append((float(times.min()), corners, points, times))
    return sorted(groups, key=lambda group: group[0])


def shade(frame, intensity, glow, core):
    mask = Image.fromarray(intensity)
    halo = mask.filter(ImageFilter.GaussianBlur(3.2)).point(lambda value: min(158, value * 5))
    frame = Image.composite(glow, frame, halo)
    return Image.composite(core, frame, mask.filter(ImageFilter.MaxFilter(3)))


def box_lines(draw, corners, progress):
    for number, (start, end) in enumerate(EDGES):
        length = np.clip(progress * len(EDGES) - number, 0, 1)
        if length <= 0:
            break
        a, b = corners[start], corners[end]
        finish = a + length * (b - a)
        coordinates = (*a, *finish)
        draw.line(coordinates, fill=(5, 31, 33, 180), width=5)
        draw.line(coordinates, fill=(80, 255, 221, 235), width=2)


def draw_nodes(intensity, project, points, brightness):
    active = brightness >= 1
    pixels = np.rint(project(points[active])).astype(np.int32)
    x, y = pixels.T
    inside = (x >= 0) & (x < WIDTH) & (y >= 0) & (y < HEIGHT)
    np.maximum.at(intensity, (y[inside], x[inside]), brightness[active][inside].astype(np.uint8))


def frames(scene_frames, cameras, render_indices, nodes, groups):
    shape = (WIDTH, HEIGHT)
    tint = Image.new("RGB", shape, "#102127")
    backdrop = Image.new("RGB", shape, "#0b1519")
    room_corners = np.array([[ROOM_X[i], 0, ROOM_Z[j]] for i, j in
                             ((0, 0), (1, 0), (1, 1), (0, 1))], dtype=np.float32)
    glows = [Image.new("RGB", shape, color) for color in ("#34c9e8", "#31e6ab")]
    cores = [Image.new("RGB", shape, color) for color in ("#c0f8ff", "#7cffd4")]
    phase = wave_time(nodes[:, 0])
    for number, camera in enumerate(cameras):
        if number in render_indices:
            raw = scene_frames.read(WIDTH * HEIGHT * 4)
            if len(raw) != WIDTH * HEIGHT * 4:
                raise RuntimeError("Metal renderer returned an incomplete camera frame")
            original = Image.frombytes("RGBA", shape, raw).convert("RGB")
            project = projector(camera)
            matte = Image.new("L", shape)
            ImageDraw.Draw(matte).polygon([tuple(p) for p in project(room_corners)], fill=255)
            base = Image.composite(Image.blend(original, tint, .22), backdrop,
                                   matte.filter(ImageFilter.GaussianBlur(38)))
        time = number / FPS
        frame = base.copy()
        if START_SWEEP - .2 <= time < END_SWEEP + 1.9:
            age = time - phase
            peak = np.exp(-np.square(age / .18))
            tail = np.where(age > 0, np.exp(-np.maximum(age, 0) * 1.9), 0)
            intensity = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
            draw_nodes(intensity, project, nodes, np.minimum(255, 225 * peak + 44 * tail))
            frame = shade(frame, intensity, glows[0], cores[0])

        if time >= groups[0][0]:
            intensity = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
            visible = []
            for onset, corners, points, times in groups:
                age = time - onset
                if age < 0:
                    break
                particle_age = time - times
                pulse = np.where(particle_age >= 0,
                                 13 + 219 * np.exp(-np.square((particle_age - .17) / .31)), 0)
                draw_nodes(intensity, project, points, pulse)
                visible.append((project(corners), (age - .10) / .92))
            frame = shade(frame, intensity, glows[1], cores[1])
            draw = ImageDraw.Draw(frame, "RGBA")
            for corners, progress in visible:
                box_lines(draw, corners, progress)
        yield frame


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("delivery", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    assets = root / "assets/valmet"
    site = json.loads((args.delivery / "site.json").read_text())
    review = json.loads((args.delivery / "catalog/review.json").read_text())
    if (site["sourceSha256"] != json.loads((assets / "site.json").read_text())["sourceSha256"]
            or site["sourceSha256"] != review["sourceSha256"]):
        raise ValueError("Scan and review must use the same registration")
    splats = np.memmap(assets / "boiler-room-sh.splats", dtype="<f4", mode="r").reshape(-1, 40)
    nodes = source_nodes(splats)
    with np.load(args.delivery / "catalog/memberships.npz") as membership:
        groups = groups_for(site, membership, splats)
    if not len(nodes) or not groups:
        raise ValueError("Animation requires observed splats and approved memberships")

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".scan-animation-") as directory:
        work = Path(directory)
        cameras = [camera_at(number / FPS) for number in range(DURATION * FPS)]
        render_indices = {0} | {n for n in range(1, len(cameras))
                                if any(not np.array_equal(a, b)
                                       for a, b in zip(cameras[n], cameras[n - 1]))}
        shots = work / "shots.json"
        shots.write_text(json.dumps([
            {"eye": cameras[n][0].tolist(), "lookAt": cameras[n][1].tolist(),
             "cutHeight": CUT_HEIGHT, "orthographicSpan": cameras[n][2], "output": "-"}
            for n in sorted(render_indices)
        ]))
        renderer = work / "render"
        subprocess.run(["swiftc", "-O", "tools/build_pump_references.swift", "-o", str(renderer)],
                       cwd=root, check=True)
        draft = work / "draft.mov"
        command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
                   "-pixel_format", "rgb24", "-video_size", f"{WIDTH}x{HEIGHT}", "-framerate",
                   str(FPS), "-i", "-", "-c:v", "prores", "-profile:v", "2",
                   "-pix_fmt", "yuv422p10le", "-threads", "4", str(draft)]
        with subprocess.Popen([str(renderer), "--desktop-frames-hd", str(shots)],
                              cwd=root, stdout=subprocess.PIPE) as scene:
            with subprocess.Popen(command, stdin=subprocess.PIPE) as encoder:
                with encoder.stdin:
                    for frame in frames(scene.stdout, cameras, render_indices, nodes, groups):
                        encoder.stdin.write(frame.tobytes())
                if encoder.wait() != 0:
                    raise RuntimeError("Could not encode scan frames")
            if scene.wait() != 0:
                raise RuntimeError("Could not render tracked room frames")
        encoded = work / "video.mp4"
        subprocess.run(["avconvert", "--source", str(draft), "--preset", "Preset1920x1080",
                        "--output", str(encoded)], check=True)
        encoded.replace(output)
    print(f"{output} · {len(nodes)} visible source nodes · {len(groups)} approved groups")


if __name__ == "__main__":
    main()
