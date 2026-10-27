#!/usr/bin/env python3
"""Safely import the G11 cloud art delivery without replacing existing art.

The delivery uses three source animation schemas.  Existing action metadata has
an ``actions`` map, so front-chat clips are normalized into that map.  New side
clips are written as ``g11_animation.json`` in one stable schema.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

from PIL import Image


DEFAULT_SOURCE = Path(
    "/Users/kari/Documents/动物餐厅游戏素材/G11_云端重绘_v2_20261027/"
    "G11_cloud_art_v2"
)
SPECIES = ("cat", "dog", "panda", "capybara", "hamster")
EXPECTED_PNG_COUNT = 267
DELIVERY_ROOTS = (
    ("batch1/assets/side", "assets/side"),
    ("batch1/assets/actions", "assets/actions"),
    ("batch1/assets/props", "assets/props"),
    ("batch1/restaurant_art/props", "restaurant_art/props"),
    ("batch2/restaurant_art/props", "restaurant_art/props"),
)


class ImportRefused(RuntimeError):
    """Raised before any write when the delivery cannot be safely merged."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def png_paths(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.png") if path.is_file())


def assert_rgba_binary_alpha(path: Path) -> None:
    with Image.open(path) as image:
        if image.mode != "RGBA":
            raise ImportRefused(f"{path}: expected RGBA, got {image.mode}")
        alpha_values = set(image.getchannel("A").getdata())
        if not alpha_values.issubset({0, 255}):
            raise ImportRefused(f"{path}: alpha is not binary")


def delivery_mapping(source: Path, destination: Path) -> list[tuple[Path, Path, str]]:
    mapping: list[tuple[Path, Path, str]] = []
    for source_relative, destination_relative in DELIVERY_ROOTS:
        source_root = source / source_relative
        if not source_root.is_dir():
            raise ImportRefused(f"missing delivery root: {source_root}")
        for png in png_paths(source_root):
            relative = png.relative_to(source)
            target = destination / destination_relative / png.relative_to(source_root)
            mapping.append((png, target, relative.as_posix()))
    if len(mapping) != EXPECTED_PNG_COUNT:
        raise ImportRefused(
            f"delivery PNG count is {len(mapping)}, expected {EXPECTED_PNG_COUNT}"
        )
    if len({target for _, target, _ in mapping}) != len(mapping):
        raise ImportRefused("delivery maps multiple PNGs to the same target")
    return mapping


def validation_hashes(source: Path) -> dict[str, str]:
    validation = read_json(source / "FINAL_VALIDATION.json")
    if validation.get("status") != "PASS":
        raise ImportRefused("FINAL_VALIDATION.json does not report PASS")
    files = validation.get("files")
    if not isinstance(files, list) or len(files) != EXPECTED_PNG_COUNT:
        raise ImportRefused("FINAL_VALIDATION.json does not contain 267 file entries")
    hashes: dict[str, str] = {}
    for entry in files:
        if not isinstance(entry, dict) or not entry.get("pass"):
            raise ImportRefused("FINAL_VALIDATION.json contains a failing file entry")
        relative = entry.get("file")
        digest = entry.get("sha256")
        if not isinstance(relative, str) or not isinstance(digest, str):
            raise ImportRefused("FINAL_VALIDATION.json has an invalid hash entry")
        hashes[relative] = digest
    if len(hashes) != EXPECTED_PNG_COUNT:
        raise ImportRefused("FINAL_VALIDATION.json has duplicate or missing PNG paths")
    return hashes


def clip_container(metadata: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    for key in ("actions", "animations", "clips"):
        value = metadata.get(key)
        if isinstance(value, dict):
            return key, value
    raise ImportRefused("animation metadata has no actions/animations/clips map")


def pivot_pair(value: Any, description: str) -> list[int]:
    """Return a validated two-coordinate pivot without silently changing it."""
    if (
        not isinstance(value, list)
        or len(value) != 2
        or any(isinstance(coordinate, bool) or not isinstance(coordinate, int) for coordinate in value)
    ):
        raise ImportRefused(f"{description}: pivot must be a two-integer list")
    return copy.deepcopy(value)


def clip_frame_pivots(
    name: str, clip: dict[str, Any], raw_frames: list[Any], fallback_pivot: list[int]
) -> list[list[int]]:
    """Resolve source pivots once per frame, preserving explicit source values.

    Batch1 uses both ``frames[].pivot`` and ``per_frame_pivot`` depending on
    species. The former wins only for that frame; the clip pivot is the
    documented fallback for clips with no per-frame declaration.
    """
    count = len(raw_frames)
    source_per_frame = clip.get("per_frame_pivot")
    if source_per_frame is not None:
        if not isinstance(source_per_frame, list) or len(source_per_frame) != count:
            raise ImportRefused(f"{name}: per_frame_pivot does not match frame count")
        validated_per_frame = [
            pivot_pair(value, f"{name}: per_frame_pivot {index}")
            for index, value in enumerate(source_per_frame)
        ]
    else:
        validated_per_frame = []
    clip_pivot = pivot_pair(clip.get("pivot", fallback_pivot), f"{name}: pivot")
    pivots: list[list[int]] = []
    for index, frame in enumerate(raw_frames):
        if not isinstance(frame, dict):
            raise ImportRefused(f"{name}: non-object frame")
        if "pivot" in frame:
            pivots.append(pivot_pair(frame["pivot"], f"{name}: frame {index}"))
        elif validated_per_frame:
            pivots.append(validated_per_frame[index])
        else:
            pivots.append(copy.deepcopy(clip_pivot))
    return pivots


def normalize_clip(
    name: str,
    clip: dict[str, Any],
    fallback_pivot: list[int],
    fallback_direction: str,
    canonical_frame_pivots: bool = False,
) -> dict[str, Any]:
    raw_frames = clip.get("frame_rects")
    if not isinstance(raw_frames, list):
        raw_frames = clip.get("frames")
    if not isinstance(raw_frames, list) or not raw_frames:
        raise ImportRefused(f"{name}: no frame list")
    count = int(clip.get("frame_count", len(raw_frames)))
    if count != len(raw_frames):
        raise ImportRefused(f"{name}: frame_count does not match frame list")
    durations = clip.get("duration_ms")
    if not isinstance(durations, list) or len(durations) != count:
        raise ImportRefused(f"{name}: duration_ms does not match frame count")
    pivots = clip_frame_pivots(name, clip, raw_frames, fallback_pivot)
    frame_rects: list[dict[str, Any]] = []
    bounds: list[Any] = []
    for index, frame in enumerate(raw_frames):
        if not isinstance(frame, dict):
            raise ImportRefused(f"{name}: non-object frame")
        frame_bounds = frame.get("bounds")
        if frame_bounds is None:
            source_bounds = clip.get("bounds")
            frame_bounds = source_bounds[index] if isinstance(source_bounds, list) and len(source_bounds) == count else None
        if not isinstance(frame_bounds, list) or len(frame_bounds) != 4:
            raise ImportRefused(f"{name}: missing four-value bounds for frame {index}")
        bounds.append(copy.deepcopy(frame_bounds))
        frame_rect = {
            "x": int(frame.get("x", index * 128)),
            "y": int(frame.get("y", 0)),
            "w": int(frame.get("w", 128)),
            "h": int(frame.get("h", 128)),
            "duration_ms": int(frame.get("duration_ms", durations[index])),
            "file": str(frame.get("file", f"frames/{name}_{index:02d}.png")),
        }
        if canonical_frame_pivots:
            frame_rect["pivot"] = pivots[index]
        frame_rects.append(frame_rect)
    normalized: dict[str, Any] = {
        "sheet": str(clip.get("sheet", f"{name}.png")),
        "frames": count,
        "duration_ms": [int(value) for value in durations],
        "loop": bool(clip.get("loop", False)),
        "playback": "loop" if bool(clip.get("loop", False)) else "once",
        "bounds": bounds,
        "frame_rects": frame_rects,
        "pivot": copy.deepcopy(clip.get("pivot", fallback_pivot)),
        "direction": str(clip.get("direction", fallback_direction)),
    }
    if canonical_frame_pivots:
        normalized["per_frame_pivot"] = pivots
    if isinstance(clip.get("hands_foreground"), list):
        normalized["hands_foreground"] = copy.deepcopy(clip["hands_foreground"])
    return normalized


def normalized_side_metadata(source: Path, species: str) -> dict[str, Any]:
    raw = read_json(source / "batch1/assets/side" / species / "animation.json")
    if not isinstance(raw, dict):
        raise ImportRefused(f"{species}: invalid side metadata")
    source_schema, clips = clip_container(raw)
    pivot = pivot_pair(raw.get("pivot", [64, 110]), f"{species}: pivot")
    actions = {
        name: normalize_clip(name, clip, pivot, "right", canonical_frame_pivots=True)
        for name, clip in sorted(clips.items())
    }
    hands_directory = source / "batch1/assets/side" / species / "hands_foreground"
    hands = [f"hands_foreground/eat_{index:02d}.png" for index in range(4)]
    available_hands = [hands_directory / Path(hand).name for hand in hands]
    if any(path.exists() for path in available_hands):
        if not all(path.is_file() for path in available_hands):
            raise ImportRefused(f"{species}: incomplete eat hands_foreground delivery")
        if "eat" not in actions:
            raise ImportRefused(f"{species}: hands_foreground exists without eat action")
        actions["eat"]["hands_foreground"] = hands
    return {
        "schema": "g11.side_animation.v1",
        "source_schema": source_schema,
        "species": species,
        "frame_size": copy.deepcopy(raw.get("frame_size", [128, 128])),
        "pivot": pivot,
        "standing_pivot": pivot_pair(
            raw.get("standing_pivot", [64, 120]), f"{species}: standing_pivot"
        ),
        "direction": "right",
        "actions": actions,
    }


def legacy_normalized_side_metadata(source: Path, species: str) -> dict[str, Any]:
    """Recreate precisely the pre-pivot generated payload for safe migration."""
    raw = read_json(source / "batch1/assets/side" / species / "animation.json")
    if not isinstance(raw, dict):
        raise ImportRefused(f"{species}: invalid side metadata")
    source_schema, clips = clip_container(raw)
    pivot = pivot_pair(raw.get("pivot", [64, 110]), f"{species}: pivot")
    actions = {
        name: normalize_clip(name, clip, pivot, "right")
        for name, clip in sorted(clips.items())
    }
    hands_directory = source / "batch1/assets/side" / species / "hands_foreground"
    hands = [f"hands_foreground/eat_{index:02d}.png" for index in range(4)]
    available_hands = [hands_directory / Path(hand).name for hand in hands]
    if any(path.exists() for path in available_hands):
        if not all(path.is_file() for path in available_hands):
            raise ImportRefused(f"{species}: incomplete eat hands_foreground delivery")
        if "eat" not in actions:
            raise ImportRefused(f"{species}: hands_foreground exists without eat action")
        actions["eat"]["hands_foreground"] = hands
    return {
        "schema": "g11.side_animation.v1",
        "source_schema": source_schema,
        "species": species,
        "frame_size": copy.deepcopy(raw.get("frame_size", [128, 128])),
        "pivot": pivot,
        "standing_pivot": pivot_pair(
            raw.get("standing_pivot", [64, 120]), f"{species}: standing_pivot"
        ),
        "direction": "right",
        "actions": actions,
    }


def merged_action_metadata(destination: Path, source: Path, species: str) -> dict[str, Any]:
    target = destination / "assets/actions" / species / "animation.json"
    existing = read_json(target)
    if not isinstance(existing, dict) or not isinstance(existing.get("actions"), dict):
        raise ImportRefused(f"{target}: existing metadata lacks actions map")
    raw = read_json(source / "batch1/assets/actions" / species / "animation.json")
    if not isinstance(raw, dict):
        raise ImportRefused(f"{species}: invalid front-chat metadata")
    _, source_clips = clip_container(raw)
    if set(source_clips) != {"chat"}:
        raise ImportRefused(f"{species}: source must contain only chat")
    pivot = copy.deepcopy(existing.get("pivot", raw.get("pivot", [64, 110])))
    chat = normalize_clip("chat", source_clips["chat"], pivot, "front_down")
    merged = copy.deepcopy(existing)
    present = merged["actions"].get("chat")
    if present is not None and present != chat:
        raise ImportRefused(f"{target}: existing chat metadata differs; refusing overwrite")
    merged["actions"]["chat"] = chat
    return merged


def merged_anchors(destination: Path, source: Path) -> dict[str, Any]:
    target = destination / "assets/props/anchors.json"
    existing = read_json(target)
    additions = read_json(source / "batch1/assets/props/anchors.json")
    if not isinstance(existing, dict) or not isinstance(additions, dict):
        raise ImportRefused("assets/props/anchors.json must be object-shaped")
    merged = copy.deepcopy(existing)
    for key, value in additions.items():
        if key in merged and merged[key] != value:
            raise ImportRefused(f"{target}: anchor {key} differs; refusing overwrite")
        merged[key] = copy.deepcopy(value)
    return merged


def merged_restaurant_props(destination: Path, source: Path) -> dict[str, Any]:
    target = destination / "restaurant_art/props.json"
    existing = read_json(target)
    batch1 = read_json(source / "batch1/restaurant_art/props.json")
    batch2 = read_json(source / "batch2/restaurant_art/props.json")
    if not isinstance(existing, dict) or not isinstance(existing.get("props"), dict):
        raise ImportRefused(f"{target}: existing metadata lacks props map")
    if not isinstance(batch1, dict) or not isinstance(batch2, dict) or not isinstance(batch2.get("assets"), dict):
        raise ImportRefused("G11 restaurant metadata has an invalid shape")
    merged = copy.deepcopy(existing)
    additions: dict[str, Any] = {}
    for key, value in batch1.items():
        if not isinstance(value, dict):
            raise ImportRefused(f"batch1 restaurant prop {key} is not an object")
        entry = copy.deepcopy(value)
        entry["file"] = f"props/{key}.png"
        additions[key] = entry
    for key, value in batch2["assets"].items():
        if not isinstance(value, dict):
            raise ImportRefused(f"batch2 restaurant prop {key} is not an object")
        additions[key] = copy.deepcopy(value)
    for key, value in additions.items():
        if key in merged["props"] and merged["props"][key] != value:
            raise ImportRefused(f"{target}: prop {key} differs; refusing overwrite")
        merged["props"][key] = value
    for source_key, target_key in (("variant_aliases", "g11_variant_aliases"), ("notes", "g11_notes")):
        value = batch2.get(source_key)
        if value is not None:
            if target_key in merged and merged[target_key] != value:
                raise ImportRefused(f"{target}: {target_key} differs; refusing overwrite")
            merged[target_key] = copy.deepcopy(value)
    return merged


def json_payload(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def write_json_if_changed(path: Path, value: Any, check_only: bool) -> bool:
    payload = json_payload(value)
    if path.exists() and path.read_text(encoding="utf-8") == payload:
        return False
    if check_only:
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".g11-tmp")
    temporary.write_text(payload, encoding="utf-8")
    os.replace(temporary, path)
    return True


def validate_landed_pngs(
    mapping: list[tuple[Path, Path, str]], expected_hashes: dict[str, str]
) -> int:
    """Require every delivered PNG to be present and identical after import."""
    for _, target_png, relative in mapping:
        if not target_png.is_file():
            raise ImportRefused(f"missing landed target PNG: {target_png}")
        assert_rgba_binary_alpha(target_png)
        if sha256(target_png) != expected_hashes[relative]:
            raise ImportRefused(f"{target_png}: landed hash differs from FINAL_VALIDATION.json")
    return len(mapping)


def validate_landed_metadata(metadata: list[tuple[Path, dict[str, Any]]]) -> int:
    """Require every generated or merged metadata payload to match exactly."""
    for path, expected in metadata:
        if not path.is_file():
            raise ImportRefused(f"missing landed metadata: {path}")
        if read_json(path) != expected:
            raise ImportRefused(f"{path}: landed metadata differs from required G11 merge")
    return len(metadata)


def run(source: Path, destination: Path, check_only: bool) -> None:
    source = source.resolve()
    destination = destination.resolve()
    mapping = delivery_mapping(source, destination)
    expected_hashes = validation_hashes(source)
    mapped_relatives = {relative for _, _, relative in mapping}
    if mapped_relatives != set(expected_hashes):
        missing = sorted(set(expected_hashes) - mapped_relatives)
        extra = sorted(mapped_relatives - set(expected_hashes))
        raise ImportRefused(f"delivery manifest mismatch: missing={missing[:3]} extra={extra[:3]}")
    for source_png, target_png, relative in mapping:
        assert_rgba_binary_alpha(source_png)
        digest = sha256(source_png)
        if digest != expected_hashes[relative]:
            raise ImportRefused(f"{source_png}: hash differs from FINAL_VALIDATION.json")
        if target_png.exists() and sha256(target_png) != digest:
            raise ImportRefused(f"{target_png}: exists with different content; refusing overwrite")

    if check_only:
        landed_pngs = validate_landed_pngs(mapping, expected_hashes)

    metadata: list[tuple[Path, dict[str, Any]]] = []
    for species in SPECIES:
        side_target = destination / "assets/side" / species / "g11_animation.json"
        side_metadata = normalized_side_metadata(source, species)
        if side_target.exists():
            existing_side_metadata = read_json(side_target)
            legacy_side_metadata = legacy_normalized_side_metadata(source, species)
            if (
                existing_side_metadata != side_metadata
                and existing_side_metadata != legacy_side_metadata
            ):
                raise ImportRefused(
                    f"{side_target}: existing generated metadata differs; refusing overwrite"
                )
        metadata.append((side_target, side_metadata))
        metadata.append((destination / "assets/actions" / species / "animation.json", merged_action_metadata(destination, source, species)))
    metadata.append((destination / "assets/props/anchors.json", merged_anchors(destination, source)))
    metadata.append((destination / "restaurant_art/props.json", merged_restaurant_props(destination, source)))

    if check_only:
        landed_metadata = validate_landed_metadata(metadata)
        print(f"G11_CHECK_PASS png={landed_pngs} metadata={landed_metadata}")
        return

    for source_png, target_png, _ in mapping:
        if not target_png.exists():
            target_png.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_png, target_png)
    changed_metadata = sum(write_json_if_changed(path, value, check_only) for path, value in metadata)

    landed = 0
    for source_png, target_png, relative in mapping:
        if not target_png.is_file():
            raise ImportRefused(f"{target_png}: was not created")
        assert_rgba_binary_alpha(target_png)
        if sha256(target_png) != expected_hashes[relative]:
            raise ImportRefused(f"{target_png}: landed hash mismatch")
        landed += 1
    mode = "CHECK" if check_only else "IMPORT"
    print(f"G11_{mode}_PASS png={landed} metadata_changed={changed_metadata}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--destination", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate the fully landed import without writing",
    )
    args = parser.parse_args()
    try:
        run(args.source, args.destination, args.check)
    except (ImportRefused, OSError, json.JSONDecodeError) as error:
        print(f"G11_IMPORT_REFUSED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
