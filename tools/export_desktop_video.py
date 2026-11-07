#!/usr/bin/env python3
"""Render a private Mac MP4 from the registered scan and exported person route."""

import argparse
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
import tempfile
from textwrap import wrap

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from spatial_navigation import Journey, plan_route, verify_route


SIZE = (1280, 720)
FPS = 24
SCENE = (36, 119, 884, 596)
PANEL = (908, 119, 1244, 596)
INK = "#edf5f3"
MUTED = "#a6bcbe"
MINT = "#65e6be"
GOLD = "#ffce74"
BLUE = "#b4cdff"
DARK = "#111e23"
PUMP = "boiler-room:red-circulation-pump"


def load(path):
    return json.loads(path.read_text())


@lru_cache
def font(size, bold=False):
    return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=int(bold))


def label(draw, xy, text, size, color=INK, bold=False):
    draw.text(xy, text, font=font(size, bold), fill=color)


def project(points, eye, look_at):
    """Match build_pump_references.swift's 1.35-zoom Metal projection."""
    eye = np.asarray(eye)
    forward = np.asarray(look_at) - eye
    forward /= np.linalg.norm(forward)
    right = np.cross(forward, [0., 1., 0.])
    right /= np.linalg.norm(right)
    up = np.cross(right, forward)
    vectors = np.asarray(points) - eye
    depth = vectors @ forward
    if (depth <= .04).any():
        raise ValueError("A route point is behind the desktop camera")
    left, top, right_px, bottom = SCENE
    focal = 1.35 * (bottom - top) / 2
    return list(zip((left + right_px) / 2 + focal * (vectors @ right) / depth,
                    (top + bottom) / 2 - focal * (vectors @ up) / depth))


def frame_base(scene, tag, status, stage):
    frame = Image.new("RGB", SIZE, "#091317")
    draw = ImageDraw.Draw(frame)
    label(draw, (36, 26), "VALMET  /  FIELD-SERVICE COPILOT", 15, MINT, True)
    label(draw, (36, 49), "Kohdehaku laitetilassa", 40, INK, True)
    label(draw, (1026, 65), "3D-SKANNI  /  SIMULAATIO", 15, MUTED, True)
    left, top, right, bottom = SCENE
    frame.paste(scene.resize((right - left, bottom - top), Image.Resampling.LANCZOS), (left, top))
    draw.rounded_rectangle(PANEL, radius=16, fill=DARK, outline="#31444b")
    label(draw, (934, 143), stage, 16, MINT, True)
    label(draw, (934, 174), tag, 48, INK, True)
    label(draw, (934, 236), status, 16, GOLD, True)
    draw.line((934, 274, 1218, 274), fill="#385056", width=1)
    label(draw, (36, 666), "Equipment Room · rekisteröity Gaussian-splat-skannaus", 17, MUTED)
    label(draw, (931, 666), "Synteettinen aineisto", 17, MUTED)
    return frame


def badge(draw, xy, text):
    x, y = xy
    width = draw.textlength(text, font=font(14, True))
    draw.rounded_rectangle((x, y, x + width + 24, y + 29), radius=8, fill="#101f23")
    label(draw, (x + 12, y + 6), text, 14, INK, True)


def point(draw, xy, radius, color):
    x, y = xy
    draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=color,
                 outline="#101f23", width=3)


def draw_extractions(frame, bounds_and_colors, eye, look_at):
    left, top, right, bottom = SCENE
    layer = Image.new("RGBA", (right - left, bottom - top))
    draw = ImageDraw.Draw(layer)
    for bounds, color in bounds_and_colors:
        corners = [[bounds[(i >> j) & 1][j] for j in range(3)] for i in range(8)]
        projected = project(corners, eye, look_at)
        for i, (x, y) in enumerate(projected):
            for axis in (1, 2, 4):
                if not i & axis:
                    end_x, end_y = projected[i | axis]
                    line = (x-left, y-top, end_x-left, end_y-top)
                    draw.line(line, fill="#112327", width=4)
                    draw.line(line, fill=color, width=2)
    frame.paste(layer, (left, top), layer)


def make_frames(site, route, target, report, review, work, root):
    cell = site["cellSize"]
    waypoints = [((x + .5) * cell, .05, (z + .5) * cell) for x, z in route["route"]]
    look = np.mean([np.min(waypoints, axis=0), np.max(waypoints, axis=0)], axis=0)
    span = max(np.ptp(waypoints, axis=0))
    scale = max(.86, span / 3)
    eye = look + scale * np.array([-2.5, 6.1, 3.2])
    service = target["serviceViewpoint"]
    room_look = np.array([site["width"] * cell / 2, 0, site["depth"] * cell / 2])
    room_eye = room_look + [-3.4, 9., 6.]
    reviewed = next((o for o in site["objects"] if o.get("geometryOnly")), None)
    shots = [
        {"eye": room_eye.tolist(), "lookAt": room_look.tolist(), "cutHeight": 2.2},
        {"eye": eye.tolist(), "lookAt": look.tolist(), "cutHeight": 2.2},
        {"eye": service["eye"], "lookAt": service["lookAt"]},
    ]
    if reviewed:
        decision = review["decisions"][reviewed["objectId"]]
        reviewed_look = np.mean(reviewed["bounds"], axis=0).tolist()
        if decision["status"] != "accepted" or len(decision["views"]) < 2:
            raise ValueError("The geometry-only object needs two reviewed angles")
        shots.extend({"eye": position, "lookAt": reviewed_look} for position in decision["views"][:2])
    for i, shot in enumerate(shots):
        shot["output"] = str(work / f"shot-{i}.png")
    plan = work / "shots.json"
    plan.write_text(json.dumps(shots))
    subprocess.run(["swift", "tools/build_pump_references.swift", "--desktop-frames", str(plan)],
                   cwd=root, check=True)

    pixels = project(waypoints, eye, look)
    if any(not (SCENE[0]+25 < x < SCENE[2]-25 and SCENE[1]+25 < y < SCENE[3]-25)
           for x, y in pixels):
        raise ValueError("The route exceeds the render area")

    tag = report["tag"]
    condition = {"attention_required": "Vaatii huomiota"}.get(report["condition"], report["condition"])
    found = frame_base(Image.open(shots[0]["output"]), "3D-rajaus", "Offline-laskenta", "01  /  EROTTELU")
    fitted = sorted((o["extractionBounds"] for o in site["objects"]
                     if o.get("extraction", {}).get("status") == "fitted"),
                    key=lambda bounds: bounds[0][0])
    statuses = {key: item["status"] for key, item in review["decisions"].items()}
    proposals = sorted(
        ((candidate["bounds"], statuses.get(candidate["objectId"], "pending"))
         for candidate in review["candidates"] if statuses.get(candidate["objectId"])
         not in ("rejected", "superseded")),
        key=lambda item: item[0][0],
    )
    fitted_frames = FPS * 5
    proposal_frames = FPS * 6
    for index in range(FPS * (18 if reviewed else 30)):
        if index % 8 == 0:
            fitted_count = min(len(fitted), len(fitted) * index // fitted_frames)
            proposal_count = min(len(proposals), len(proposals) * max(0, index - 7 * FPS)
                                 // proposal_frames)
            visible = proposals[:proposal_count]
            frame = found.copy()
            draw_extractions(frame, [(bounds, MINT) for bounds in fitted[:fitted_count]] +
                             [(bounds, BLUE if status == "accepted" else GOLD)
                              for bounds, status in visible], room_eye, room_look)
            d = ImageDraw.Draw(frame)
            badge(d, (SCENE[0]+15, SCENE[1]+14), "LEIKKAUSKORKEUS 2,2 M")
            label(d, (934, 294), str(fitted_count), 35, MINT, True)
            label(d, (934, 337), "Lähtörajoihin sovitetut", 20, INK, True)
            label(d, (934, 365), "Pistegeometriasta lasketut rajat", 16, MUTED)
            label(d, (934, 419), str(proposal_count), 35, GOLD, True)
            label(d, (934, 462), "Erilliset ehdotukset", 20, INK, True)
            label(d, (934, 490), "Haku ilman lähtörajausta", 16, MUTED)
            accepted = sum(status == "accepted" for _, status in visible)
            label(d, (934, 522), f"{accepted} hyväksytty tarkastuksessa", 16, BLUE)
            label(d, (36, 618), "Skannin pistegeometriasta lasketut kolmiulotteiset rajaukset.", 22)
        yield frame

    for number, shot in enumerate(shots[3:], start=1):
        reviewed_frame = frame_base(Image.open(shot["output"]), "Katselmus",
                                    "Hyväksytty geometrinen kohde", "02  /  TARKASTUS")
        draw_extractions(reviewed_frame, [(reviewed["bounds"], BLUE)], shot["eye"], shot["lookAt"])
        d = ImageDraw.Draw(reviewed_frame)
        badge(d, (SCENE[0]+15, SCENE[1]+14), f"TARKASTUSKUVAKULMA {number}/2")
        for i, line in enumerate(wrap(reviewed["name"], width=22)):
            label(d, (934, 296 + 27 * i), line, 22, INK, True)
        label(d, (934, 377), f"{reviewed['supportingSplats']} Gaussian-pistettä", 18, MUTED)
        label(d, (934, 410), "Löytyi ilman lähtörajausta", 17, MUTED)
        label(d, (934, 462), "Ei työkirjakytkentää", 17, BLUE)
        caption = "Kohde varmennettiin kahdesta suunnasta."
        if reviewed["name"] == "Freestanding display stand":
            caption = "Vapaasti seisova näyttöteline varmennettiin kahdesta suunnasta."
        label(d, (36, 618), caption, 22)
        for _ in range(6 * FPS):
            yield reviewed_frame

    overview = frame_base(Image.open(shots[1]["output"]), tag, condition,
                          "03  /  REITTI" if reviewed else "02  /  REITTI")
    draw_extractions(overview, [(target["extractionBounds"], MINT)], eye, look)
    d = ImageDraw.Draw(overview)
    d.line(pixels, fill="#112327", width=11, joint="curve")
    d.line(pixels, fill="#e9a947", width=5, joint="curve")
    point(d, pixels[0], 7, INK)
    point(d, pixels[-1], 10, GOLD)
    badge(d, (SCENE[0]+15, SCENE[1]+14), "LEIKKAUSKORKEUS 2,2 M")
    label(d, (934, 296), "Automaattinen kulkureitti", 21, INK, True)
    label(d, (934, 333), "Leveys 0,60 m · korkeus 1,80 m", 17, MUTED)
    label(d, (934, 360), "Ylävara 0,05 m", 17, MUTED)
    label(d, (934, 395), "Turkoosi · sovitettu kohderajaus", 16, MINT)
    label(d, (36, 618), "Varmennettu mallireitti huoltopisteeseen · hidastettu toisto 0,5×", 22)

    arrival = frame_base(Image.open(shots[2]["output"]), tag, condition,
                         "04  /  SAAPUMINEN" if reviewed else "03  /  SAAPUMINEN")
    draw_extractions(arrival, [(target["extractionBounds"], MINT)], service["eye"], service["lookAt"])
    d = ImageDraw.Draw(arrival)
    badge(d, (SCENE[0]+15, SCENE[1]+14), "HUOLTONÄKYMÄ")
    label(d, (934, 296), "Tarkista seuraavaksi", 21, INK, True)
    check = {"inspect hydraulic path": "Tarkista hydraulinen virtausreitti."}.get(
        report["nextCheck"], report["nextCheck"])
    for i, line in enumerate(wrap(check, width=29)):
        label(d, (934, 332 + 25 * i), line, 20)
    observation = report["observations"][0]
    references = observation["references"]
    health = re.search(r"health (\d+); urgency (\w+)", observation["text"])
    if health and health[2] == "high":
        label(d, (934, 404), f"Kunto {health[1]}/100 · korkea kiireellisyys", 16, INK)
    label(d, (934, 443), "Lähde · " + ", ".join(references), 17, MUTED)
    label(d, (934, 492), "Vian syy vahvistamatta.", 17, MUTED)
    label(d, (934, 521), "Aineisto ei ole reaaliaikaista.", 17, MUTED)
    label(d, (36, 618), "Saapuminen avaa työkirjaan sidotun tarkastusraportin.", 22)

    journey = Journey(route["route"], cell, speed=site["navigationProfile"]["speedMetresPerSecond"])
    journey.play()
    for index in range(15 * FPS):
        if index > 3 * FPS:
            journey.advance(.5 / FPS)
        x, _, z = journey.position
        current = project([(x, .05, z)], eye, look)[0]
        frame = overview.copy()
        d = ImageDraw.Draw(frame)
        point(d, current, 11, MINT)
        badge(d, (current[0] - 34, current[1] - 48), "HENKILÖ")
        remaining = max(0, journey.length_metres - journey.travelled)
        label(d, (934, 439), f"{remaining:.1f}".replace(".", ",") + " m", 43, MINT, True)
        label(d, (935, 495), "Jäljellä huoltopisteeseen", 17, MUTED)
        d.rounded_rectangle((934, 548, 1218, 555), radius=3, fill="#2a4048")
        progress = 284 * journey.travelled / journey.length_metres
        if progress >= 1:
            d.rounded_rectangle((934, 548, 934 + progress, 555), radius=3, fill=MINT)
        yield frame
    for _ in range(18 * FPS):
        yield arrival


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("delivery", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    site_path = args.delivery / "site.json"
    site = load(site_path)
    route_path = args.delivery / "route-P-005.json"
    route = load(route_path) if route_path.is_file() else plan_route(site_path, site["start"], PUMP)
    diagnostics = load(args.delivery / "diagnostics.json")
    review = load(args.delivery / "catalog/review.json")
    if site["sourceSha256"] != load(root / "assets/valmet/site.json")["sourceSha256"]:
        raise ValueError("Delivery site uses a different registered scan")
    if review["sourceSha256"] != site["sourceSha256"] or diagnostics["sceneSourceSha256"] != site["sourceSha256"]:
        raise ValueError("Review or report uses a different registered scan")
    if route["status"] != "ready" or len(route["route"]) < 2:
        raise ValueError("P-005 needs a verified walking route")
    verify_route(site, route)
    target = next(obj for obj in site["objects"] if obj["objectId"] == PUMP)
    if (route.get("targetId", PUMP) != PUMP or route["route"][0] != route.get("start", site["start"])
            or route["route"][-1] != target["service"]):
        raise ValueError("Route endpoints do not match the exported P-005 plan")
    report = diagnostics["reports"][PUMP]
    if not report["synthetic"] or report["tag"] != "P-005":
        raise ValueError("Expected the synthetic P-005 report")

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".desktop-video-") as temp:
        work = Path(temp)
        draft = work / "draft.mov"
        frames = iter(make_frames(site, route, target, report, review, work, root))
        first = next(frames)
        ffmpeg = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
                  "-pixel_format", "rgb24", "-video_size", f"{SIZE[0]}x{SIZE[1]}",
                  "-framerate", str(FPS), "-i", "-", "-c:v", "prores", "-profile:v", "2",
                  "-pix_fmt", "yuv422p10le", str(draft)]
        with subprocess.Popen(ffmpeg, stdin=subprocess.PIPE) as encoder:
            with encoder.stdin:
                encoder.stdin.write(first.tobytes())
                for frame in frames:
                    encoder.stdin.write(frame.tobytes())
            if encoder.wait() != 0:
                raise RuntimeError("Could not encode desktop frames")
        encoded = work / "video.mp4"
        subprocess.run(["avconvert", "--source", str(draft), "--preset", "Preset1280x720",
                        "--output", str(encoded)], check=True)
        encoded.replace(output)
    print(output)


if __name__ == "__main__":
    main()
