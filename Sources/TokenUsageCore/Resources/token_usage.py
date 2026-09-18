#!/usr/bin/python3
"""Local, model-free token accounting for Codex Desktop/CLI sessions.

The hook path reads only a small allowlist of transcript fields. It never sends
data over the network and never returns model-visible additionalContext.

The Codex transcript JSONL format is explicitly not a stable hook API. This
parser therefore records the Codex version, tolerates unknown records, and
fails open when a future format is not understood.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import struct
import sys
import unicodedata
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple
from urllib.parse import quote
from uuid import UUID


CACHE_SCHEMA_VERSION = 15
RATE_LIMIT_RESET_JITTER_SECONDS = 300
CHECKPOINT_BYTES = 4096
REPORT_SCHEMA_VERSION = 1
PROMPT_PREVIEW_CHARACTERS = 240
IMAGE_HEADER_BYTES = 256 * 1024
USAGE_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)
COUNT_FIELDS = (
    "image_inputs",
    "audio_inputs",
    "image_generations",
    "web_searches",
    "mcp_calls",
    "tool_calls",
)
FAST_TIERS = {"fast", "priority"}
STANDARD_TIERS = {"default", "standard"}
SCRIPT_DIR = Path(__file__).resolve().parent
CATALOG_PATH = SCRIPT_DIR / "pricing_catalog.json"
WORD_JOINER = "\u2060"


def _codex_dir() -> Path:
    override = os.environ.get("CODEX_TOKEN_USAGE_CODEX_DIR")
    return Path(override).expanduser() if override else Path.home() / ".codex"


def _state_dir() -> Path:
    override = os.environ.get("CODEX_TOKEN_USAGE_STATE_DIR")
    return Path(override).expanduser() if override else _codex_dir() / "token-usage"


def _is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _validate_transcript_path(path: Path) -> Path:
    expanded = path.expanduser()
    if expanded.is_symlink():
        raise ValueError("transcript symlinks are not accepted")
    resolved = expanded.resolve(strict=True)
    if not resolved.is_file() or not resolved.name.startswith("rollout-") or resolved.suffix != ".jsonl":
        raise ValueError("not a Codex rollout JSONL file")
    if os.environ.get("CODEX_TOKEN_USAGE_ALLOW_ANY_TRANSCRIPT") == "1":
        return resolved
    allowed_roots = ((_codex_dir() / "sessions").resolve(), (_codex_dir() / "archived_sessions").resolve())
    if not any(_is_relative_to(resolved, root) for root in allowed_roots):
        raise ValueError("transcript is outside Codex session directories")
    return resolved


def _ensure_private_state_root() -> Path:
    root = _state_dir()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        root.chmod(0o700)
    except OSError:
        pass
    return root


@contextmanager
def _transcript_lock(transcript_path: Path) -> Iterable[None]:
    digest = hashlib.sha256(str(transcript_path).encode("utf-8", "replace")).hexdigest()
    lock_path = _ensure_private_state_root() / "locks" / f"{digest}.lock"
    lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    acquired = False
    try:
        # Never let a reporting collision hold up the Stop hook. A concurrent
        # invocation may omit its UI summary, but the Codex turn always wins.
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquired = True
        yield
    finally:
        if acquired:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _zero_usage() -> Dict[str, int]:
    return {field: 0 for field in USAGE_FIELDS}


def _zero_counts() -> Dict[str, int]:
    return {field: 0 for field in COUNT_FIELDS}


def _as_int(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return max(value, 0)
    if isinstance(value, float):
        return max(int(value), 0)
    return 0


def _usage_from(value: Any) -> Dict[str, int]:
    source = value if isinstance(value, dict) else {}
    usage = {field: _as_int(source.get(field)) for field in USAGE_FIELDS}
    if not usage["total_tokens"] and (usage["input_tokens"] or usage["output_tokens"]):
        usage["total_tokens"] = usage["input_tokens"] + usage["output_tokens"]
    return usage


def _add_usage(left: Dict[str, int], right: Dict[str, int]) -> Dict[str, int]:
    result = {field: _as_int(left.get(field)) + _as_int(right.get(field)) for field in USAGE_FIELDS}
    result["total_tokens"] = result["input_tokens"] + result["output_tokens"]
    return result


def _sum_usage(values: Iterable[Dict[str, int]]) -> Dict[str, int]:
    result = _zero_usage()
    for value in values:
        result = _add_usage(result, value)
    return result


def _add_counts(left: Dict[str, int], right: Dict[str, int]) -> Dict[str, int]:
    return {field: _as_int(left.get(field)) + _as_int(right.get(field)) for field in COUNT_FIELDS}


def _sum_counts(values: Iterable[Dict[str, int]]) -> Dict[str, int]:
    result = _zero_counts()
    for value in values:
        result = _add_counts(result, value)
    return result


def _usage_difference(current: Dict[str, int], baseline: Dict[str, int]) -> Tuple[Dict[str, int], bool]:
    current_value = _usage_from(current)
    baseline_value = _usage_from(baseline)
    negative = any(baseline_value[field] > current_value[field] for field in USAGE_FIELDS)
    result = {
        field: max(current_value[field] - baseline_value[field], 0)
        for field in USAGE_FIELDS
    }
    result["total_tokens"] = result["input_tokens"] + result["output_tokens"]
    return result, negative


def _counts_difference(current: Dict[str, int], baseline: Dict[str, int]) -> Tuple[Dict[str, int], bool]:
    current_value = current if isinstance(current, dict) else {}
    baseline_value = baseline if isinstance(baseline, dict) else {}
    negative = any(_as_int(baseline_value.get(field)) > _as_int(current_value.get(field)) for field in COUNT_FIELDS)
    return (
        {
            field: max(_as_int(current_value.get(field)) - _as_int(baseline_value.get(field)), 0)
            for field in COUNT_FIELDS
        },
        negative,
    )


def _usage_delta(current: Dict[str, int], previous: Dict[str, int]) -> Tuple[Dict[str, int], bool, bool]:
    reset = any(current[field] < previous[field] for field in USAGE_FIELDS)
    if reset:
        # The observed Codex counters are cumulative and monotonic within a
        # task epoch. The caller handles an explicit task-boundary rebase; any
        # other lower sample may be stale, and counting it as a new segment can
        # massively double-count. Preserve the last known lower bound instead.
        return _zero_usage(), True, False
    else:
        delta = {field: current[field] - previous[field] for field in USAGE_FIELDS}
    expected_total = delta["input_tokens"] + delta["output_tokens"]
    total_mismatch = bool(delta["total_tokens"] and delta["total_tokens"] != expected_total)
    delta["total_tokens"] = expected_total
    return delta, reset, total_mismatch


def _iso_to_epoch(value: Any) -> Optional[float]:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _utc_iso(value: Any) -> Optional[str]:
    if isinstance(value, bool):
        return None
    try:
        if isinstance(value, (int, float)):
            parsed = datetime.fromtimestamp(float(value), timezone.utc)
        elif isinstance(value, str) and value:
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                parsed = datetime.fromtimestamp(float(value), timezone.utc)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            else:
                parsed = parsed.astimezone(timezone.utc)
        else:
            return None
    except (OSError, OverflowError, ValueError):
        return None
    return parsed.isoformat().replace("+00:00", "Z")


def _rate_limit_snapshot_key(value: Dict[str, Any]) -> Tuple[Any, Any, Any]:
    return value.get("limit_id"), value.get("bucket"), value.get("window_minutes")


def _same_rate_limit_period(lhs: Dict[str, Any], rhs: Dict[str, Any]) -> bool:
    if _rate_limit_snapshot_key(lhs) != _rate_limit_snapshot_key(rhs):
        return False
    lhs_reset = _iso_to_epoch(lhs.get("resets_at"))
    rhs_reset = _iso_to_epoch(rhs.get("resets_at"))
    if lhs_reset is None or rhs_reset is None:
        return lhs.get("resets_at") == rhs.get("resets_at")
    return lhs_reset == rhs_reset


def _add_rate_limit_snapshot(
    container: List[Dict[str, Any]], candidate: Dict[str, Any]
) -> None:
    for index in range(len(container) - 1, -1, -1):
        existing = container[index]
        if not _same_rate_limit_period(existing, candidate):
            continue
        existing_epoch = _iso_to_epoch(existing.get("observed_at"))
        candidate_epoch = _iso_to_epoch(candidate.get("observed_at"))
        if existing_epoch is None or (
            candidate_epoch is not None and candidate_epoch >= existing_epoch
        ):
            container[index] = candidate
        return
    container.append(candidate)


def _rate_limit_observation_day(value: Dict[str, Any]) -> Tuple[str, str]:
    observed_at = value.get("observed_at")
    if not isinstance(observed_at, str):
        return "", ""
    try:
        timestamp = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    except ValueError:
        return observed_at[:10], observed_at[:10]
    return timestamp.date().isoformat(), timestamp.astimezone().date().isoformat()


def _same_rate_limit_observation_day_period(
    lhs: Dict[str, Any], rhs: Dict[str, Any]
) -> bool:
    if _rate_limit_snapshot_key(lhs) != _rate_limit_snapshot_key(rhs):
        return False
    if _rate_limit_observation_day(lhs) != _rate_limit_observation_day(rhs):
        return False
    lhs_reset = _iso_to_epoch(lhs.get("resets_at"))
    rhs_reset = _iso_to_epoch(rhs.get("resets_at"))
    return (
        lhs_reset is not None
        and rhs_reset is not None
        and abs(lhs_reset - rhs_reset) <= RATE_LIMIT_RESET_JITTER_SECONDS
    )


def _add_rate_limit_observation(
    container: List[Dict[str, Any]],
    candidate: Dict[str, Any],
    indices: Dict[str, List[int]],
) -> None:
    """Keep the first and last poll per calendar day and reset period.

    A report may span many Stop events. Retaining the first and last observation
    for both UTC and the machine's local day preserves daily boundaries without
    serializing every token_count event. A five-minute reset-time tolerance
    absorbs server timestamp jitter. Per-stream indices avoid scanning an ever
    growing timeline in the Stop Hook. The local day uses the machine timezone
    when the report is generated, matching the app's current calendar.
    """
    stream_key = json.dumps(_rate_limit_snapshot_key(candidate), separators=(",", ":"))
    matching = indices.get(stream_key, [])
    if not matching:
        indices[stream_key] = [len(container)]
        container.append(candidate)
        return

    latest_index = matching[-1]
    latest = container[latest_index]
    if latest == candidate:
        return
    latest_epoch = _iso_to_epoch(latest.get("observed_at"))
    candidate_epoch = _iso_to_epoch(candidate.get("observed_at"))
    if latest_epoch is not None and candidate_epoch is not None and candidate_epoch < latest_epoch:
        indices[stream_key] = [latest_index, len(container)]
        container.append(candidate)
        return

    if _same_rate_limit_observation_day_period(latest, candidate) and len(matching) == 2:
        previous = container[matching[0]]
        if _same_rate_limit_observation_day_period(previous, candidate):
            container[latest_index] = candidate
            return
    indices[stream_key] = [latest_index, len(container)]
    container.append(candidate)


def _capture_rate_limit_snapshots(
    state: Dict[str, Any], payload: Dict[str, Any], timestamp: Any
) -> None:
    rate_limits = payload.get("rate_limits")
    observed_at = _utc_iso(timestamp)
    if not isinstance(rate_limits, dict) or observed_at is None:
        return

    shared_limit_id = rate_limits.get("limit_id")
    shared_limit_name = rate_limits.get("limit_name")
    shared_plan_type = rate_limits.get("plan_type")
    container = state.setdefault("rate_limit_snapshots", [])
    observations = state.setdefault("rate_limit_observations", [])
    observation_indices = state.setdefault("rate_limit_observation_indices", {})

    for bucket in ("primary", "secondary"):
        bucket_value = rate_limits.get(bucket)
        if not isinstance(bucket_value, dict):
            continue
        used_percent = bucket_value.get("used_percent")
        if isinstance(used_percent, bool) or not isinstance(used_percent, (int, float)):
            continue
        try:
            if not Decimal(str(used_percent)).is_finite():
                continue
        except InvalidOperation:
            continue
        window_minutes = _as_int(bucket_value.get("window_minutes"))
        resets_at = _utc_iso(bucket_value.get("resets_at"))
        if not window_minutes or resets_at is None:
            continue

        limit_id = bucket_value.get("limit_id")
        if not isinstance(limit_id, str) or not limit_id:
            limit_id = shared_limit_id
        if not isinstance(limit_id, str) or not limit_id:
            continue
        limit_name = bucket_value.get("limit_name")
        if not isinstance(limit_name, str) or not limit_name:
            limit_name = shared_limit_name
        plan_type = bucket_value.get("plan_type")
        if not isinstance(plan_type, str) or not plan_type:
            plan_type = shared_plan_type
        candidate: Dict[str, Any] = {
            "observed_at": observed_at,
            "limit_id": limit_id,
            "bucket": bucket,
            "used_percent": used_percent,
            "window_minutes": window_minutes,
            "resets_at": resets_at,
        }
        if isinstance(limit_name, str) and limit_name:
            candidate["limit_name"] = limit_name
        if isinstance(plan_type, str) and plan_type:
            candidate["plan_type"] = plan_type
        _add_rate_limit_snapshot(container, candidate)
        _add_rate_limit_observation(observations, candidate, observation_indices)


def _merge_rate_limit_snapshots(
    values: Iterable[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    candidates = [dict(value) for value in values if isinstance(value, dict)]
    candidates.sort(
        key=lambda value: (
            str(value.get("observed_at") or ""),
            str(value.get("limit_id") or ""),
            str(value.get("bucket") or ""),
        )
    )
    result: List[Dict[str, Any]] = []
    for candidate in candidates:
        _add_rate_limit_snapshot(result, candidate)
    result.sort(
        key=lambda value: (
            str(value.get("observed_at") or ""),
            str(value.get("limit_id") or ""),
            str(value.get("bucket") or ""),
        )
    )
    return result


def _merge_rate_limit_observations(
    values: Iterable[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    candidates = [dict(value) for value in values if isinstance(value, dict)]
    candidates.sort(
        key=lambda value: (
            str(value.get("observed_at") or ""),
            str(value.get("limit_id") or ""),
            str(value.get("bucket") or ""),
        )
    )
    result: List[Dict[str, Any]] = []
    indices: Dict[str, List[int]] = {}
    for candidate in candidates:
        _add_rate_limit_observation(result, candidate, indices)
    return result


def _request_heading_body(line: str) -> Optional[str]:
    match = re.match(
        r"^\s*#{1,6}\s*(?:my\s+request(?:\s+for\s+codex)?|我的请求)\s*:?[ \t]*(.*)$",
        line,
        flags=re.IGNORECASE,
    )
    return match.group(1) if match else None


def _is_attachment_header(line: str) -> bool:
    return re.match(
        r"^\s{0,3}#{1,6}\s*(?:(?:files?\s+(?:mentioned|metioned|attached|uploaded)\s+by\s+(?:the\s+)?user)|(?:(?:attached|uploaded)\s+files?))\s*:?\s*$",
        line,
        flags=re.IGNORECASE,
    ) is not None


def _is_attachment_directive(line: str) -> bool:
    lowered = line.strip().lower()
    return (
        lowered.startswith("distinguish instructions")
        and ("attached" in lowered or "uploaded" in lowered)
        and "request" in lowered
    )


def _is_attached_file_entry(line: str) -> bool:
    if not line.lstrip().startswith("#") or ":" not in line:
        return False
    value = line.split(":", 1)[1].strip()
    return bool(
        value.startswith(("/", "~", "file://", "http://", "https://"))
        or re.match(r"^[A-Za-z]:[\\/]", value)
        or "codex-clipboard-" in value
    )


def _user_request_text(value: str) -> str:
    text = value.replace("\ufeff", "").replace("\0", "")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    first_index = next((index for index, line in enumerate(lines) if line.strip()), None)
    if first_index is None:
        return text
    inline = _request_heading_body(lines[first_index])
    if inline is not None:
        return "\n".join([inline] + lines[first_index + 1 :])
    if not (
        _is_attachment_header(lines[first_index])
        or _is_attachment_directive(lines[first_index])
    ):
        return text
    for index in range(first_index + 1, len(lines)):
        line = lines[index].strip()
        inline = _request_heading_body(line)
        if inline is not None:
            return "\n".join([inline] + lines[index + 1 :])
        if (
            not line
            or _is_attachment_header(line)
            or _is_attachment_directive(line)
            or _is_attached_file_entry(line)
        ):
            continue
        return "\n".join(lines[index:])
    return ""


def _text_preview(value: Any, user_message: bool = False) -> Tuple[Optional[str], Optional[bool]]:
    if not isinstance(value, str):
        return None, None
    source = _user_request_text(value) if user_message else value
    normalized = " ".join(source.split()).strip()
    if not normalized:
        return None, None
    if len(normalized) <= PROMPT_PREVIEW_CHARACTERS:
        return normalized, False
    return normalized[: PROMPT_PREVIEW_CHARACTERS - 1] + "…", True


def _image_dimensions(header: bytes) -> Tuple[Optional[str], Optional[int], Optional[int]]:
    if len(header) >= 24 and header.startswith(b"\x89PNG\r\n\x1a\n"):
        width, height = struct.unpack(">II", header[16:24])
        return "png", width or None, height or None
    if len(header) >= 10 and header[:6] in {b"GIF87a", b"GIF89a"}:
        width, height = struct.unpack("<HH", header[6:10])
        return "gif", width or None, height or None
    if len(header) >= 30 and header.startswith(b"RIFF") and header[8:12] == b"WEBP":
        chunk = header[12:16]
        if chunk == b"VP8X":
            width = 1 + int.from_bytes(header[24:27], "little")
            height = 1 + int.from_bytes(header[27:30], "little")
            return "webp", width, height
        if chunk == b"VP8L" and header[20] == 0x2F:
            bits = int.from_bytes(header[21:25], "little")
            return "webp", (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if chunk == b"VP8 " and header[23:26] == b"\x9d\x01\x2a":
            width = int.from_bytes(header[26:28], "little") & 0x3FFF
            height = int.from_bytes(header[28:30], "little") & 0x3FFF
            return "webp", width or None, height or None
        return "webp", None, None
    if len(header) >= 4 and header.startswith(b"\xff\xd8"):
        index = 2
        start_of_frame = {
            0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
            0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
        }
        while index + 8 <= len(header):
            while index < len(header) and header[index] != 0xFF:
                index += 1
            while index < len(header) and header[index] == 0xFF:
                index += 1
            if index >= len(header):
                break
            marker = header[index]
            index += 1
            if marker in {0x01, *range(0xD0, 0xD9)}:
                continue
            if marker == 0xDA or index + 2 > len(header):
                break
            length = int.from_bytes(header[index : index + 2], "big")
            if length < 2 or index + length > len(header):
                break
            if marker in start_of_frame and length >= 7:
                height = int.from_bytes(header[index + 3 : index + 5], "big")
                width = int.from_bytes(header[index + 5 : index + 7], "big")
                return "jpeg", width or None, height or None
            index += length
        return "jpeg", None, None
    return None, None, None


def _base64_image_metadata(value: Any) -> Dict[str, Any]:
    if not isinstance(value, str) or not value:
        return {}
    encoded = value.split(",", 1)[1] if value.startswith("data:") and "," in value else value
    encoded = re.sub(r"\s+", "", encoded)
    if not encoded or len(encoded) > 70_000_000:
        return {}
    if re.fullmatch(r"[A-Za-z0-9+/=_-]+", encoded) is None:
        return {}
    unpadded = encoded.rstrip("=")
    output_bytes = (len(unpadded) * 6) // 8
    prefix_characters = min(
        len(encoded),
        ((IMAGE_HEADER_BYTES + 2) // 3) * 4,
    )
    prefix_characters -= prefix_characters % 4
    try:
        header = base64.b64decode(
            encoded[:prefix_characters] + "=" * ((-prefix_characters) % 4),
            altchars=b"-_",
            validate=False,
        )
    except (ValueError, TypeError):
        return {}
    output_format, width, height = _image_dimensions(header)
    result: Dict[str, Any] = {"output_bytes": output_bytes}
    if output_format:
        result["output_format"] = output_format
    if width:
        result["actual_width"] = width
    if height:
        result["actual_height"] = height
    return result


def _call_digest(field: str, value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value:
        return None
    return hashlib.sha256(f"{field}\0{value}".encode("utf-8", "replace")).hexdigest()[:24]


def _append_warning(state: Dict[str, Any], warning: str) -> None:
    warnings = state.setdefault("warnings", [])
    if warning not in warnings and len(warnings) < 50:
        warnings.append(warning)


def _atomic_write(path: Path, text: str) -> None:
    _ensure_private_state_root()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(text, encoding="utf-8")
    try:
        temporary.chmod(0o600)
    except OSError:
        pass
    os.replace(str(temporary), str(path))


def _cache_path(transcript_path: Path) -> Path:
    digest = hashlib.sha256(str(transcript_path).encode("utf-8", "replace")).hexdigest()
    return _state_dir() / "cache" / f"{digest}.json"


def _checkpoint_hash(transcript_path: Path, offset: int) -> str:
    length = min(max(offset, 0), CHECKPOINT_BYTES)
    start = max(offset - length, 0)
    with transcript_path.open("rb") as handle:
        handle.seek(start)
        value = handle.read(length)
    return hashlib.sha256(value).hexdigest()


def _new_parser_state(transcript_path: Path, stat_result: os.stat_result) -> Dict[str, Any]:
    return {
        "cache_schema_version": CACHE_SCHEMA_VERSION,
        "transcript_path": str(transcript_path),
        "file_dev": stat_result.st_dev,
        "file_ino": stat_result.st_ino,
        "offset": 0,
        "thread_id": None,
        "forked_from_id": None,
        "parent_thread_id": None,
        "cli_version": None,
        "originator": None,
        "first_record_seen": False,
        "session_meta_seen": False,
        "active_turn_id": None,
        "settings": {"model": None, "effort": None, "tier": None},
        "last_total_usage": _zero_usage(),
        "last_total_usage_task_epoch": 0,
        "raw_usage": _zero_usage(),
        "raw_counts": _zero_counts(),
        "seen_call_hashes": {},
        "unclassified_compaction_total": 0,
        "record_sequence": 0,
        "task_epoch": 0,
        "task_boundaries": [],
        "turn_order": [],
        "turns": {},
        "turn_user_prompts": {},
        "pending_user_prompt": None,
        "image_generation_details": [],
        "unattributed_segments": [],
        "usage_samples": [],
        "rate_limit_snapshots": [],
        "rate_limit_observations": [],
        "rate_limit_observation_indices": {},
        "unattributed_counts": _zero_counts(),
        "last_event_at": None,
        "parse_errors": 0,
        "warnings": [],
    }


def _load_parser_state(transcript_path: Path, stat_result: os.stat_result) -> Optional[Dict[str, Any]]:
    try:
        value = json.loads(_cache_path(transcript_path).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    if not isinstance(value, dict):
        return None
    if value.get("cache_schema_version") != CACHE_SCHEMA_VERSION:
        return None
    if value.get("transcript_path") != str(transcript_path):
        return None
    if value.get("file_dev") != stat_result.st_dev or value.get("file_ino") != stat_result.st_ino:
        return None
    offset = _as_int(value.get("offset"))
    if offset > stat_result.st_size:
        return None
    expected_hash = value.get("checkpoint_hash")
    if not isinstance(expected_hash, str) or expected_hash != _checkpoint_hash(transcript_path, offset):
        return None
    return value


def _save_parser_state(transcript_path: Path, state: Dict[str, Any]) -> None:
    _atomic_write(
        _cache_path(transcript_path),
        json.dumps(state, ensure_ascii=False, separators=(",", ":")),
    )


def _ensure_turn(state: Dict[str, Any], turn_id: Any, timestamp: Any = None) -> Optional[Dict[str, Any]]:
    if not isinstance(turn_id, str) or not turn_id:
        return None
    turns = state["turns"]
    turn = turns.get(turn_id)
    if turn is None:
        settings = state.get("settings") or {}
        turn = {
            "turn_id": turn_id,
            "started_at": timestamp if isinstance(timestamp, str) else None,
            "completed_at": None,
            "duration_ms": None,
            "ttft_ms": None,
            "model": settings.get("model"),
            "effort": settings.get("effort"),
            "tier": settings.get("tier"),
            "tier_source": "thread_settings" if settings.get("tier") else None,
            "usage": _zero_usage(),
            "segments": [],
            "counts": _zero_counts(),
            "agent_thread_ids": [],
            "aborted": False,
            "first_usage_at": None,
            "last_usage_at": None,
        }
        turns[turn_id] = turn
        state["turn_order"].append(turn_id)
    elif isinstance(timestamp, str) and not turn.get("started_at"):
        turn["started_at"] = timestamp
    return turn


def _segment_key(segment: Dict[str, Any]) -> Tuple[Any, ...]:
    return (
        segment.get("model"),
        segment.get("effort"),
        segment.get("tier"),
        bool(segment.get("long_context")),
        segment.get("tier_source"),
        _as_int(segment.get("task_epoch")),
    )


def _utc_minute(timestamp: Any) -> Optional[str]:
    if not isinstance(timestamp, str) or not timestamp:
        return None
    try:
        value = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    value = value.astimezone(timezone.utc).replace(second=0, microsecond=0)
    return value.isoformat().replace("+00:00", "Z")


def _usage_sample_key(sample: Dict[str, Any]) -> Tuple[Any, ...]:
    return (
        sample.get("minute"),
        sample.get("thread_id"),
        sample.get("turn_id"),
        sample.get("model"),
        sample.get("effort"),
        sample.get("tier"),
        sample.get("tier_source"),
        _as_int(sample.get("task_epoch")),
        bool(sample.get("long_context")),
    )


def _add_usage_sample(
    container: List[Dict[str, Any]],
    metadata: Dict[str, Any],
    usage: Dict[str, int],
    timestamp: Any,
    request_count: int = 1,
) -> None:
    """Add one positive cumulative-counter delta to the minute accounting plane."""
    if not usage["total_tokens"]:
        return
    candidate = {
        "minute": _utc_minute(timestamp),
        "thread_id": metadata.get("thread_id"),
        "turn_id": metadata.get("turn_id"),
        "model": metadata.get("model"),
        "effort": metadata.get("effort"),
        "tier": metadata.get("tier"),
        "tier_source": metadata.get("tier_source"),
        "task_epoch": _as_int(metadata.get("task_epoch")),
        "long_context": _long_context_for_request(metadata.get("model"), usage),
        "usage": dict(usage),
        "request_count": max(_as_int(request_count), 1),
    }
    key = _usage_sample_key(candidate)
    for sample in container:
        if _usage_sample_key(sample) == key:
            sample["usage"] = _add_usage(sample["usage"], usage)
            sample["request_count"] = (
                _as_int(sample.get("request_count")) + candidate["request_count"]
            )
            return
    container.append(candidate)


def _long_context_for_request(model: Any, usage: Dict[str, int]) -> bool:
    if not isinstance(model, str):
        return False
    catalog = _load_catalog()
    _, entry = _model_entry(catalog, model)
    api = entry.get("api_usd") if isinstance(entry, dict) and isinstance(entry.get("api_usd"), dict) else {}
    threshold = api.get("long_context_threshold_input_tokens_exclusive")
    if threshold is None and isinstance(api.get("long_context_rule"), dict):
        threshold = api["long_context_rule"].get("threshold_input_tokens_exclusive")
    return isinstance(threshold, int) and usage["input_tokens"] > threshold


def _add_segment(container: List[Dict[str, Any]], metadata: Dict[str, Any], usage: Dict[str, int], timestamp: Any) -> None:
    if not usage["total_tokens"]:
        return
    candidate = {
        "model": metadata.get("model"),
        "effort": metadata.get("effort"),
        "tier": metadata.get("tier"),
        "tier_source": metadata.get("tier_source"),
        "task_epoch": _as_int(metadata.get("task_epoch")),
        "long_context": _long_context_for_request(metadata.get("model"), usage),
        "usage": dict(usage),
        "first_at": timestamp if isinstance(timestamp, str) else None,
        "last_at": timestamp if isinstance(timestamp, str) else None,
        "request_count": 1,
    }
    key = _segment_key(candidate)
    for segment in container:
        if _segment_key(segment) == key:
            segment["usage"] = _add_usage(segment["usage"], usage)
            segment["request_count"] = _as_int(segment.get("request_count")) + 1
            if isinstance(timestamp, str):
                segment["last_at"] = timestamp
            return
    container.append(candidate)


def _increment_count(
    state: Dict[str, Any], field: str, amount: int = 1, dedupe_key: Any = None
) -> bool:
    if field not in COUNT_FIELDS or amount <= 0:
        return False
    digest = _call_digest(field, dedupe_key)
    if digest:
        seen_by_field = state.setdefault("seen_call_hashes", {})
        seen = seen_by_field.setdefault(field, [])
        if digest in seen:
            return False
        if len(seen) < 100000:
            seen.append(digest)
    active_turn_id = state.get("active_turn_id")
    turn = _ensure_turn(state, active_turn_id) if active_turn_id else None
    target = turn["counts"] if turn else state["unattributed_counts"]
    target[field] = _as_int(target.get(field)) + amount
    raw_counts = state.setdefault("raw_counts", _zero_counts())
    raw_counts[field] = _as_int(raw_counts.get(field)) + amount
    return True


def _remember_user_prompt(state: Dict[str, Any], value: Any) -> None:
    preview, truncated = _text_preview(value, user_message=True)
    if preview is None:
        return
    prompt = {"text": preview, "truncated": bool(truncated)}
    turn_id = state.get("active_turn_id")
    if isinstance(turn_id, str) and turn_id:
        state.setdefault("turn_user_prompts", {})[turn_id] = prompt
    else:
        state["pending_user_prompt"] = prompt


def _process_record(state: Dict[str, Any], record: Dict[str, Any]) -> None:
    timestamp = record.get("timestamp")
    if isinstance(timestamp, str):
        state["last_event_at"] = timestamp
    record_type = record.get("type")
    payload = record.get("payload") if isinstance(record.get("payload"), dict) else {}

    if not state.get("first_record_seen"):
        state["first_record_seen"] = True
        if record_type != "session_meta":
            _append_warning(state, "the first complete transcript record was not session_meta")

    if record_type == "session_meta":
        if not state.get("session_meta_seen"):
            state["session_meta_seen"] = True
            state["thread_id"] = payload.get("id") if isinstance(payload.get("id"), str) else None
            state["forked_from_id"] = payload.get("forked_from_id") if isinstance(payload.get("forked_from_id"), str) else None
            state["parent_thread_id"] = payload.get("parent_thread_id") if isinstance(payload.get("parent_thread_id"), str) else None
            state["cli_version"] = payload.get("cli_version") if isinstance(payload.get("cli_version"), str) else None
            state["originator"] = payload.get("originator") if isinstance(payload.get("originator"), str) else None
        return

    if record_type == "turn_context":
        turn_id = payload.get("turn_id")
        state["active_turn_id"] = turn_id if isinstance(turn_id, str) else state.get("active_turn_id")
        turn = _ensure_turn(state, state.get("active_turn_id"), timestamp)
        model = payload.get("model")
        effort = payload.get("effort")
        if isinstance(model, str):
            state["settings"]["model"] = model
            if turn:
                turn["model"] = model
        if isinstance(effort, str):
            state["settings"]["effort"] = effort
            if turn:
                turn["effort"] = effort
        return

    if record_type == "response_item":
        item_type = payload.get("type")
        if item_type == "message" and payload.get("role") == "user":
            content = payload.get("content") if isinstance(payload.get("content"), list) else []
            message_id = payload.get("id")
            _increment_count(
                state,
                "image_inputs",
                sum(1 for item in content if isinstance(item, dict) and item.get("type") == "input_image"),
                message_id,
            )
            _increment_count(
                state,
                "audio_inputs",
                sum(1 for item in content if isinstance(item, dict) and item.get("type") == "input_audio"),
                message_id,
            )
            text = "\n".join(
                item.get("text")
                for item in content
                if isinstance(item, dict)
                and item.get("type") in {"input_text", "text"}
                and isinstance(item.get("text"), str)
            )
            turn_id = state.get("active_turn_id")
            prompts = state.setdefault("turn_user_prompts", {})
            if text and not (isinstance(turn_id, str) and turn_id in prompts):
                _remember_user_prompt(state, text)
        elif item_type in {"function_call", "custom_tool_call"}:
            _increment_count(state, "tool_calls", dedupe_key=payload.get("call_id") or payload.get("id"))
        return

    if record_type != "event_msg":
        return

    event_type = payload.get("type")
    if event_type == "user_message":
        _remember_user_prompt(state, payload.get("message"))
        return

    if event_type == "thread_settings_applied":
        settings = payload.get("thread_settings") if isinstance(payload.get("thread_settings"), dict) else {}
        model = settings.get("model")
        effort = settings.get("reasoning_effort")
        tier = settings.get("service_tier")
        if isinstance(model, str):
            state["settings"]["model"] = model
        if isinstance(effort, str):
            state["settings"]["effort"] = effort
        if isinstance(tier, str):
            state["settings"]["tier"] = tier
        return

    if event_type == "task_started":
        turn_id = payload.get("turn_id")
        if isinstance(turn_id, str):
            state["task_epoch"] = _as_int(state.get("task_epoch")) + 1
            boundary = {
                "turn_id": turn_id,
                "record_sequence": _as_int(state.get("record_sequence")),
                "task_epoch": state["task_epoch"],
                "raw_usage_before": _usage_from(state.get("raw_usage")),
                "cumulative_usage_before": _usage_from(state.get("last_total_usage")),
                "raw_counts_before": dict(state.get("raw_counts") or _zero_counts()),
            }
            state.setdefault("task_boundaries", []).append(boundary)
            state["active_turn_id"] = turn_id
            turn = _ensure_turn(state, turn_id, timestamp)
            if turn:
                turn["start_sequence"] = boundary["record_sequence"]
                turn["task_epoch"] = boundary["task_epoch"]
                pending_prompt = state.get("pending_user_prompt")
                if isinstance(pending_prompt, dict):
                    state.setdefault("turn_user_prompts", {})[turn_id] = pending_prompt
                    state["pending_user_prompt"] = None
        return

    if event_type == "task_complete":
        turn_id = payload.get("turn_id") or state.get("active_turn_id")
        turn = _ensure_turn(state, turn_id)
        if turn:
            turn["completed_at"] = timestamp if isinstance(timestamp, str) else turn.get("completed_at")
            turn["duration_ms"] = _as_int(payload.get("duration_ms")) or None
            turn["ttft_ms"] = _as_int(payload.get("time_to_first_token_ms")) or None
        if state.get("active_turn_id") == turn_id:
            state["active_turn_id"] = None
        return

    if event_type == "turn_aborted":
        turn_id = payload.get("turn_id") or state.get("active_turn_id")
        turn = _ensure_turn(state, turn_id)
        if turn:
            turn["aborted"] = True
            turn["completed_at"] = timestamp if isinstance(timestamp, str) else turn.get("completed_at")
        if state.get("active_turn_id") == turn_id:
            state["active_turn_id"] = None
        return

    if event_type == "token_count":
        _capture_rate_limit_snapshots(state, payload, timestamp)
        info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
        total_value = info.get("total_token_usage")
        if not isinstance(total_value, dict):
            return
        current = _usage_from(total_value)
        if current["cached_input_tokens"] > current["input_tokens"]:
            _append_warning(state, "cached_input_tokens exceeded input_tokens")
        if current["cache_write_input_tokens"] > current["input_tokens"]:
            _append_warning(state, "cache_write_input_tokens exceeded input_tokens")
        if current["cached_input_tokens"] + current["cache_write_input_tokens"] > current["input_tokens"]:
            _append_warning(state, "cached_input_tokens plus cache_write_input_tokens exceeded input_tokens")
        if current["reasoning_output_tokens"] > current["output_tokens"]:
            _append_warning(state, "reasoning_output_tokens exceeded output_tokens")
        previous = _usage_from(state.get("last_total_usage"))
        sample_task_epoch = _as_int(state.get("task_epoch"))
        first_sample_in_task_epoch = (
            _as_int(state.get("last_total_usage_task_epoch")) != sample_task_epoch
        )
        delta, reset, mismatch = _usage_delta(current, previous)
        if reset and first_sample_in_task_epoch:
            # Codex may restart its cumulative counters when a new task begins.
            # The first sample in that task is then the complete epoch-local
            # usage, not a stale/decreasing sample. Rebase only at this
            # explicit task boundary; a later decrease in the same task still
            # fails the monotonicity invariant below.
            delta, reset, mismatch = _usage_delta(current, _zero_usage())
        if reset:
            _append_warning(state, "token counters decreased; usage is a lower bound and price estimates were suppressed")
            return
        state["last_total_usage"] = current
        state["last_total_usage_task_epoch"] = sample_task_epoch
        if mismatch:
            _append_warning(state, "a token delta had total_tokens != input_tokens + output_tokens")
        if not delta["total_tokens"]:
            last_usage = _usage_from(info.get("last_token_usage"))
            if (
                last_usage["total_tokens"]
                and not last_usage["input_tokens"]
                and not last_usage["output_tokens"]
            ):
                state["unclassified_compaction_total"] = (
                    _as_int(state.get("unclassified_compaction_total")) + last_usage["total_tokens"]
                )
                _append_warning(state, "unclassified compaction total was excluded from priced usage")
            return
        state["raw_usage"] = _add_usage(_usage_from(state.get("raw_usage")), delta)
        turn = _ensure_turn(state, state.get("active_turn_id")) if state.get("active_turn_id") else None
        metadata = {
            "thread_id": state.get("thread_id"),
            "turn_id": state.get("active_turn_id"),
            "model": turn.get("model") if turn else state["settings"].get("model"),
            "effort": turn.get("effort") if turn else state["settings"].get("effort"),
            "tier": turn.get("tier") if turn else state["settings"].get("tier"),
            "tier_source": turn.get("tier_source") if turn else ("thread_settings" if state["settings"].get("tier") else None),
            "task_epoch": turn.get("task_epoch") if turn else state.get("task_epoch"),
        }
        if turn:
            if not turn.get("tier") and state["settings"].get("tier"):
                turn["tier"] = state["settings"]["tier"]
                turn["tier_source"] = "thread_settings"
                metadata["tier"] = turn["tier"]
                metadata["tier_source"] = turn["tier_source"]
            turn["usage"] = _add_usage(_usage_from(turn.get("usage")), delta)
            if isinstance(timestamp, str):
                turn["first_usage_at"] = turn.get("first_usage_at") or timestamp
                turn["last_usage_at"] = timestamp
            _add_segment(turn["segments"], metadata, delta, timestamp)
        else:
            _add_segment(state["unattributed_segments"], metadata, delta, timestamp)
        _add_usage_sample(state["usage_samples"], metadata, delta, timestamp)
        return

    if event_type == "image_generation_end":
        call_id = payload.get("call_id")
        if _increment_count(state, "image_generations", dedupe_key=call_id):
            turn_id = state.get("active_turn_id")
            detail_id = _call_digest("image_generations", call_id)
            if detail_id is None:
                detail_id = hashlib.sha256(
                    f"image_generations\0{state.get('record_sequence')}\0{timestamp}".encode(
                        "utf-8", "replace"
                    )
                ).hexdigest()[:24]
            detail: Dict[str, Any] = {
                "id": detail_id,
                "turn_id": turn_id if isinstance(turn_id, str) else None,
                "generated_at": timestamp if isinstance(timestamp, str) else None,
                "status": payload.get("status")[:64]
                if isinstance(payload.get("status"), str)
                else None,
                "_record_sequence": _as_int(state.get("record_sequence")),
                "_task_epoch": _as_int(state.get("task_epoch")),
            }
            prompt = state.setdefault("turn_user_prompts", {}).get(turn_id)
            if isinstance(prompt, dict) and isinstance(prompt.get("text"), str):
                detail["user_prompt_preview"] = prompt["text"]
                detail["user_prompt_truncated"] = bool(prompt.get("truncated"))
            revised_prompt, revised_truncated = _text_preview(payload.get("revised_prompt"))
            if revised_prompt is not None:
                detail["revised_prompt_preview"] = revised_prompt
                detail["revised_prompt_truncated"] = bool(revised_truncated)
            detail.update(_base64_image_metadata(payload.get("result")))
            details = state.setdefault("image_generation_details", [])
            if len(details) < 100_000:
                details.append({key: value for key, value in detail.items() if value is not None})
    elif event_type == "web_search_end":
        _increment_count(state, "web_searches", dedupe_key=payload.get("call_id"))
    elif event_type == "mcp_tool_call_end":
        _increment_count(state, "mcp_calls", dedupe_key=payload.get("call_id"))
    elif event_type == "sub_agent_activity":
        child_id = payload.get("agent_thread_id")
        turn = _ensure_turn(state, state.get("active_turn_id")) if state.get("active_turn_id") else None
        if turn and isinstance(child_id, str) and child_id and child_id not in turn["agent_thread_ids"]:
            turn["agent_thread_ids"].append(child_id)


def parse_transcript(transcript_path: Path, use_cache: bool = True) -> Dict[str, Any]:
    transcript_path = _validate_transcript_path(transcript_path)
    with _transcript_lock(transcript_path):
        stat_result = transcript_path.stat()
        snapshot_size = stat_result.st_size
        state = _load_parser_state(transcript_path, stat_result) if use_cache else None
        loaded_from_cache = state is not None
        if state is None:
            state = _new_parser_state(transcript_path, stat_result)

        offset = _as_int(state.get("offset"))
        starting_offset = offset
        with transcript_path.open("rb") as handle:
            handle.seek(offset)
            while handle.tell() < snapshot_size:
                line_start = handle.tell()
                line = handle.readline(snapshot_size - line_start)
                if not line:
                    break
                if not line.endswith(b"\n"):
                    handle.seek(line_start)
                    break
                state["offset"] = handle.tell()
                try:
                    record = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    state["parse_errors"] = _as_int(state.get("parse_errors")) + 1
                    _append_warning(state, "one or more complete transcript lines were not valid JSON")
                    continue
                if isinstance(record, dict):
                    state["record_sequence"] = _as_int(state.get("record_sequence")) + 1
                    _process_record(state, record)

        state["file_dev"] = stat_result.st_dev
        state["file_ino"] = stat_result.st_ino
        state["checkpoint_hash"] = _checkpoint_hash(transcript_path, _as_int(state.get("offset")))
        if use_cache and (not loaded_from_cache or _as_int(state.get("offset")) != starting_offset):
            _save_parser_state(transcript_path, state)
        return state


def _state_db_path(codex_dir: Path) -> Path:
    candidates = list(codex_dir.glob("state_*.sqlite"))
    if not candidates:
        raise FileNotFoundError("no Codex state database")

    def sort_key(path: Path) -> Tuple[int, int]:
        stem_value = path.stem.rsplit("_", 1)[-1]
        version = int(stem_value) if stem_value.isdigit() else -1
        try:
            modified = path.stat().st_mtime_ns
        except OSError:
            modified = 0
        return version, modified

    return max(candidates, key=sort_key).resolve()


def _connect_state_db(codex_dir: Path) -> sqlite3.Connection:
    db_path = _state_db_path(codex_dir)
    uri = "file:{}?mode=ro".format(quote(str(db_path), safe="/"))
    connection = sqlite3.connect(uri, uri=True, timeout=0.2)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    connection.execute("PRAGMA busy_timeout = 200")
    return connection


def _row_dict(row: Optional[sqlite3.Row]) -> Dict[str, Any]:
    return dict(row) if row is not None else {}


def _thread_row(connection: sqlite3.Connection, thread_id: str) -> Dict[str, Any]:
    row = connection.execute(
        "SELECT id, rollout_path, model, reasoning_effort, thread_source, agent_path, source, updated_at_ms "
        "FROM threads WHERE id = ?",
        (thread_id,),
    ).fetchone()
    return _row_dict(row)


def _resolve_transcript(row: Dict[str, Any], thread_id: str, codex_dir: Path) -> Optional[Path]:
    raw = row.get("rollout_path")
    if isinstance(raw, str) and raw:
        candidate = Path(raw).expanduser()
        try:
            resolved_candidate = candidate.resolve(strict=True)
            allowed_roots = (
                (codex_dir / "sessions").resolve(),
                (codex_dir / "archived_sessions").resolve(),
            )
        except OSError:
            resolved_candidate = None
        if (
            resolved_candidate is not None
            and resolved_candidate.is_file()
            and any(_is_relative_to(resolved_candidate, root) for root in allowed_roots)
        ):
            return resolved_candidate
        # A copied CODEX_HOME can retain an absolute rollout_path pointing at
        # the source Home. Never cross that boundary even if the old file still
        # exists; resolve the same thread under the selected Home below.
    patterns = (
        f"sessions/*/*/*/*{thread_id}*.jsonl",
        f"archived_sessions/*{thread_id}*.jsonl",
    )
    for pattern in patterns:
        for candidate in codex_dir.glob(pattern):
            if candidate.is_file():
                return candidate.resolve()
    return None


def _read_own_session_meta(path: Path) -> Dict[str, Any]:
    try:
        validated = _validate_transcript_path(path)
        with validated.open("rb") as handle:
            line = handle.readline(1024 * 1024)
        record = json.loads(line)
    except (OSError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return {}
    if not isinstance(record, dict) or record.get("type") != "session_meta":
        return {}
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return {}
    return {
        "id": payload.get("id"),
        "parent_thread_id": payload.get("parent_thread_id"),
        "forked_from_id": payload.get("forked_from_id"),
    }


def _discover_graph(connection: sqlite3.Connection, root_id: str) -> Tuple[Dict[str, Dict[str, Any]], Dict[str, str], List[str]]:
    rows: Dict[str, Dict[str, Any]] = {}
    parent_map: Dict[str, str] = {}
    warnings: List[str] = []
    root_row = _thread_row(connection, root_id)
    if root_row:
        rows[root_id] = root_row
    queue = [root_id]
    seen = {root_id}
    while queue and len(seen) < 512:
        parent_id = queue.pop(0)
        edge_rows = connection.execute(
            "SELECT e.child_thread_id, t.id, t.rollout_path, t.model, t.reasoning_effort, "
            "t.thread_source, t.agent_path, t.source, t.updated_at_ms "
            "FROM thread_spawn_edges e LEFT JOIN threads t ON t.id = e.child_thread_id "
            "WHERE e.parent_thread_id = ?",
            (parent_id,),
        ).fetchall()
        candidates = list(edge_rows)
        source_rows = connection.execute(
            "SELECT id, rollout_path, model, reasoning_effort, thread_source, agent_path, source, updated_at_ms "
            "FROM threads WHERE thread_source = 'subagent' AND source LIKE ?",
            (f"%{parent_id}%",),
        ).fetchall()
        candidates.extend(source_rows)
        for row in candidates:
            item = _row_dict(row)
            child_id = item.get("child_thread_id") or item.get("id")
            if not isinstance(child_id, str) or not child_id or child_id == parent_id:
                continue
            if child_id not in parent_map:
                parent_map[child_id] = parent_id
            rows[child_id] = _thread_row(connection, child_id) or item
            if child_id not in seen:
                seen.add(child_id)
                queue.append(child_id)
    if len(seen) >= 512:
        warnings.append("subagent discovery stopped at the 512-thread safety limit")

    # Auto-review guardian threads currently have no thread_spawn_edges row.
    # There are normally only a handful; read only their first session_meta line
    # to recover a parent link without scanning their transcript contents.
    orphan_rows = connection.execute(
        "SELECT t.id, t.rollout_path, t.model, t.reasoning_effort, t.thread_source, "
        "t.agent_path, t.source, t.updated_at_ms FROM threads t "
        "LEFT JOIN thread_spawn_edges e ON e.child_thread_id = t.id "
        "WHERE t.thread_source = 'subagent' AND e.child_thread_id IS NULL"
    ).fetchall()
    for row in orphan_rows:
        item = _row_dict(row)
        orphan_id = item.get("id")
        if not isinstance(orphan_id, str) or orphan_id in seen:
            continue
        path = _resolve_transcript(item, orphan_id, _codex_dir())
        meta = _read_own_session_meta(path) if path else {}
        parent_id = meta.get("parent_thread_id")
        if isinstance(parent_id, str) and parent_id in seen:
            parent_map[orphan_id] = parent_id
            rows[orphan_id] = item
            seen.add(orphan_id)
    return rows, parent_map, warnings


def _latest_user_thread(connection: sqlite3.Connection) -> Dict[str, Any]:
    row = connection.execute(
        "SELECT id, rollout_path, model, reasoning_effort, thread_source, agent_path, source, updated_at_ms "
        "FROM threads WHERE thread_source = 'user' ORDER BY updated_at_ms DESC LIMIT 1"
    ).fetchone()
    return _row_dict(row)


def _read_config_defaults(codex_dir: Path) -> Dict[str, Optional[str]]:
    result: Dict[str, Optional[str]] = {"model": None, "effort": None, "tier": None}
    try:
        lines = (codex_dir / "config.toml").read_text(encoding="utf-8").splitlines()
    except OSError:
        return result
    keys = {"model": "model", "model_reasoning_effort": "effort", "service_tier": "tier"}
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            if line.startswith("["):
                break
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        target = keys.get(key)
        if target and value.startswith(('"', "'")) and value.endswith(('"', "'")):
            result[target] = value[1:-1]
    return result


def _turn_time_bounds(turn: Dict[str, Any]) -> Tuple[Optional[float], Optional[float]]:
    start = _iso_to_epoch(turn.get("started_at") or turn.get("first_usage_at"))
    end = _iso_to_epoch(turn.get("completed_at") or turn.get("last_usage_at"))
    if start is None:
        start = end
    if end is None:
        end = start
    return start, end


def _intervals_overlap(left: Tuple[Optional[float], Optional[float]], right: Tuple[Optional[float], Optional[float]]) -> bool:
    if left[0] is None or left[1] is None or right[0] is None or right[1] is None:
        return False
    return left[0] <= right[1] + 2.0 and right[0] <= left[1] + 2.0


def _is_later_uuidv7(candidate: Any, boundary: Any) -> bool:
    if not isinstance(candidate, str) or not isinstance(boundary, str):
        return False
    try:
        candidate_uuid = UUID(candidate)
        boundary_uuid = UUID(boundary)
    except (ValueError, AttributeError):
        return False
    return candidate_uuid.version == 7 and boundary_uuid.version == 7 and candidate_uuid.int > boundary_uuid.int


def _owned_boundary(
    state: Dict[str, Any], parent_state: Optional[Dict[str, Any]]
) -> Tuple[List[str], str, Optional[Dict[str, Any]], List[str]]:
    turns = state.get("turns", {})
    ordered = [turn_id for turn_id in state.get("turn_order", []) if turn_id in turns]
    if not state.get("forked_from_id"):
        return ordered, "no-inherited-prefix", None, []

    boundaries = [item for item in state.get("task_boundaries", []) if isinstance(item, dict)]
    parent_candidate: Optional[Dict[str, Any]] = None
    if parent_state is not None:
        parent_ids = set(parent_state.get("turns", {}).keys())
        parent_candidate = next(
            (item for item in boundaries if item.get("turn_id") not in parent_ids),
            None,
        )
    thread_id = state.get("thread_id")
    uuid_candidate = next(
        (item for item in boundaries if _is_later_uuidv7(item.get("turn_id"), thread_id)),
        None,
    )

    warnings: List[str] = []
    if parent_candidate is not None and uuid_candidate is not None:
        if parent_candidate.get("record_sequence") == uuid_candidate.get("record_sequence"):
            boundary = parent_candidate
            method = "record-baseline-parent-turn-diff"
        else:
            # A child transcript can contain a newer copied parent turn than a
            # concurrently sampled parent file. UUIDv7 creation order is the
            # safer discriminator in that disagreement.
            boundary = uuid_candidate
            method = "record-baseline-uuidv7-crosscheck"
            warnings.append("parent snapshot and UUIDv7 child boundary disagreed; the UUIDv7 boundary was used")
    elif uuid_candidate is not None:
        boundary = uuid_candidate
        method = "record-baseline-uuidv7-heuristic"
    elif parent_candidate is not None:
        boundary = parent_candidate
        method = "record-baseline-parent-turn-diff"
    else:
        return [], "unresolved-inherited-prefix", None, [
            "inherited prefix boundary could not be resolved; exclusive usage was left unavailable"
        ]

    boundary_sequence = _as_int(boundary.get("record_sequence"))
    owned_ids = [
        turn_id
        for turn_id in ordered
        if _as_int(turns[turn_id].get("start_sequence")) >= boundary_sequence
    ]
    return owned_ids, method, boundary, warnings


def _unattributed_owned_segments(
    state: Dict[str, Any], boundary: Optional[Dict[str, Any]]
) -> List[Dict[str, Any]]:
    segments = state.get("unattributed_segments") if isinstance(state.get("unattributed_segments"), list) else []
    if not state.get("forked_from_id"):
        return list(segments)
    if boundary is None:
        return []
    boundary_epoch = _as_int(boundary.get("task_epoch"))
    return [segment for segment in segments if _as_int(segment.get("task_epoch")) >= boundary_epoch]


def _owned_usage_samples(
    state: Dict[str, Any], boundary: Optional[Dict[str, Any]]
) -> List[Dict[str, Any]]:
    samples = state.get("usage_samples") if isinstance(state.get("usage_samples"), list) else []
    if not state.get("forked_from_id"):
        return list(samples)
    if boundary is None:
        return []
    boundary_epoch = _as_int(boundary.get("task_epoch"))
    return [sample for sample in samples if _as_int(sample.get("task_epoch")) >= boundary_epoch]


def _owned_image_generations(
    state: Dict[str, Any],
    boundary: Optional[Dict[str, Any]],
    owned_turn_ids: Sequence[str],
) -> List[Dict[str, Any]]:
    details = (
        state.get("image_generation_details")
        if isinstance(state.get("image_generation_details"), list)
        else []
    )
    if not state.get("forked_from_id"):
        selected = details
    elif boundary is None:
        selected = []
    else:
        owned = set(owned_turn_ids)
        boundary_sequence = _as_int(boundary.get("record_sequence"))
        selected = [
            detail
            for detail in details
            if isinstance(detail, dict)
            and (
                detail.get("turn_id") in owned
                or (
                    not isinstance(detail.get("turn_id"), str)
                    and _as_int(detail.get("_record_sequence")) >= boundary_sequence
                )
            )
        ]
    return [
        {
            key: value
            for key, value in detail.items()
            if isinstance(key, str) and not key.startswith("_")
        }
        for detail in selected
        if isinstance(detail, dict)
    ]


def _merge_usage_samples(values: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []
    for value in values:
        usage = _usage_from(value.get("usage"))
        if not usage["total_tokens"]:
            continue
        candidate = {
            "minute": value.get("minute"),
            "thread_id": value.get("thread_id"),
            "turn_id": value.get("turn_id"),
            "model": value.get("model"),
            "effort": value.get("effort"),
            "tier": value.get("tier"),
            "tier_source": value.get("tier_source"),
            "task_epoch": _as_int(value.get("task_epoch")),
            "long_context": bool(value.get("long_context")),
            "usage": usage,
            "request_count": max(_as_int(value.get("request_count")), 1),
        }
        key = _usage_sample_key(candidate)
        for sample in result:
            if _usage_sample_key(sample) == key:
                sample["usage"] = _add_usage(sample["usage"], usage)
                sample["request_count"] = (
                    _as_int(sample.get("request_count")) + candidate["request_count"]
                )
                break
        else:
            result.append(candidate)
    result.sort(
        key=lambda sample: tuple(
            "" if item is None else str(item) for item in _usage_sample_key(sample)
        )
    )
    return result


def _thread_summary(
    thread_id: str,
    state: Dict[str, Any],
    row: Dict[str, Any],
    parent_state: Optional[Dict[str, Any]],
    parent_id: Optional[str],
) -> Dict[str, Any]:
    owned_ids, boundary_method, boundary, boundary_warnings = _owned_boundary(state, parent_state)
    turns = state.get("turns", {})
    owned_turns = [turns[turn_id] for turn_id in owned_ids if turn_id in turns]
    unattributed = _unattributed_owned_segments(state, boundary)
    owned_segments = [segment for turn in owned_turns for segment in turn.get("segments", [])] + unattributed
    owned_samples = _owned_usage_samples(state, boundary)
    owned_image_generations = _owned_image_generations(state, boundary, owned_ids)
    for detail in owned_image_generations:
        detail["thread_id"] = thread_id
    raw_usage = _usage_from(state.get("raw_usage"))
    boundary_resolved = not state.get("forked_from_id") or boundary is not None
    if state.get("forked_from_id") and boundary is None:
        inherited_usage = raw_usage
    elif state.get("forked_from_id"):
        inherited_usage = _usage_from(boundary.get("raw_usage_before"))
    else:
        inherited_usage = _zero_usage()
    exclusive_usage, negative_usage = _usage_difference(raw_usage, inherited_usage)
    raw_counts = state.get("raw_counts") if isinstance(state.get("raw_counts"), dict) else _zero_counts()
    if state.get("forked_from_id") and boundary is None:
        inherited_counts = raw_counts
    elif state.get("forked_from_id") and isinstance(boundary.get("raw_counts_before"), dict):
        inherited_counts = boundary.get("raw_counts_before")
    else:
        inherited_counts = _zero_counts()
    counts, negative_counts = _counts_difference(raw_counts, inherited_counts)
    warnings = list(state.get("warnings") or []) + boundary_warnings
    segment_usage = _sum_usage(segment.get("usage", {}) for segment in owned_segments)
    if segment_usage != exclusive_usage:
        warnings.append("exclusive usage/segment reconciliation failed; price estimates are incomplete")
    sample_usage = _sum_usage(sample.get("usage", {}) for sample in owned_samples)
    if sample_usage != exclusive_usage:
        warnings.append("exclusive usage/usage-sample reconciliation failed; price estimates are incomplete")
    if negative_usage or negative_counts:
        warnings.append("inherited baseline exceeded final counters; exclusive usage is incomplete")
    return {
        "thread_id": thread_id,
        "parent_thread_id": parent_id or state.get("parent_thread_id"),
        "forked_from_id": state.get("forked_from_id"),
        "thread_source": row.get("thread_source"),
        "agent_path": row.get("agent_path"),
        "cli_version": state.get("cli_version"),
        "boundary_method": boundary_method,
        "exclusive_usage_available": boundary_resolved and not negative_usage,
        "usage": exclusive_usage,
        "raw_cumulative_usage": raw_usage,
        "inherited_prefix_usage": inherited_usage,
        "inherited_prefix_counts": inherited_counts,
        "counts": counts,
        "owned_turn_ids": owned_ids,
        "turns": owned_turns,
        "active_turn_count": sum(
            1 for turn in owned_turns if not turn.get("completed_at") and not turn.get("aborted")
        ),
        "segments": owned_segments,
        # Private build-report plane. It is removed before thread summaries are
        # serialized so the report contains one, and only one, timeline copy.
        "_usage_samples": owned_samples,
        "_image_generations": owned_image_generations,
        "_rate_limit_snapshots": list(state.get("rate_limit_snapshots") or []),
        "_rate_limit_observations": list(state.get("rate_limit_observations") or []),
        "warnings": list(dict.fromkeys(warnings)),
        "parse_errors": _as_int(state.get("parse_errors")),
        "unclassified_compaction_total": _as_int(state.get("unclassified_compaction_total")),
    }


@lru_cache(maxsize=1)
def _load_catalog() -> Dict[str, Any]:
    try:
        value = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"models": {}, "token_unit": 1000000, "catalog_id": "missing"}
    return value if isinstance(value, dict) else {"models": {}, "token_unit": 1000000, "catalog_id": "invalid"}


def _decimal(value: Any) -> Optional[Decimal]:
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def _model_entry(catalog: Dict[str, Any], model: Any) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    if not isinstance(model, str):
        return None, None
    models = catalog.get("models") if isinstance(catalog.get("models"), dict) else {}
    if model in models:
        return model, models[model]
    for key, entry in models.items():
        aliases = entry.get("aliases") if isinstance(entry, dict) and isinstance(entry.get("aliases"), list) else []
        if model in aliases:
            return key, entry
    return None, None


def _money_text(value: Optional[Decimal], places: int = 6) -> Optional[str]:
    if value is None:
        return None
    quantizer = Decimal(1).scaleb(-places)
    return format(value.quantize(quantizer), "f")


def _calculate_cost(segments: Sequence[Dict[str, Any]], catalog: Dict[str, Any]) -> Dict[str, Any]:
    unit = Decimal(_as_int(catalog.get("token_unit")) or 1000000)
    has_usage = any(_usage_from(segment.get("usage"))["total_tokens"] for segment in segments)
    credit_standard = Decimal(0)
    credit_configured = Decimal(0)
    api_standard = Decimal(0)
    api_configured = Decimal(0)
    credit_standard_complete = has_usage
    credit_configured_complete = has_usage
    api_standard_complete = has_usage
    api_configured_complete = has_usage
    warnings: List[str] = []
    credit_unpriced_tokens = 0
    api_unpriced_tokens = 0
    credit_standard_priced_tokens = 0
    credit_configured_priced_tokens = 0
    api_standard_priced_tokens = 0
    api_configured_priced_tokens = 0
    total_usage_tokens = 0

    for segment in segments:
        usage = _usage_from(segment.get("usage"))
        total_usage_tokens += usage["total_tokens"]
        model_key, entry = _model_entry(catalog, segment.get("model"))
        if entry is None:
            credit_unpriced_tokens += usage["total_tokens"]
            api_unpriced_tokens += usage["total_tokens"]
            credit_standard_complete = credit_configured_complete = False
            api_standard_complete = api_configured_complete = False
            continue
        if entry.get("api_usd", {}).get("source_conflict") and "API price source conflict" not in warnings:
            warnings.append("API price source conflict: the canonical pricing table was used")

        if usage["cached_input_tokens"] + usage["cache_write_input_tokens"] > usage["input_tokens"]:
            credit_unpriced_tokens += usage["total_tokens"]
            api_unpriced_tokens += usage["total_tokens"]
            credit_standard_complete = credit_configured_complete = False
            api_standard_complete = api_configured_complete = False
            warnings.append("cached-input plus cache-write usage exceeded input usage; this segment was not priced")
            continue
        cached = usage["cached_input_tokens"]
        cache_write = usage["cache_write_input_tokens"]
        ordinary_for_api = max(usage["input_tokens"] - cached - cache_write, 0)
        ordinary_for_credits = max(usage["input_tokens"] - cached, 0)
        output = usage["output_tokens"]

        credit_standard_priced = False
        credit = entry.get("codex_credits") if isinstance(entry.get("codex_credits"), dict) else None
        if credit:
            input_rate = _decimal(credit.get("input"))
            cached_rate = _decimal(credit.get("cached_input"))
            output_rate = _decimal(credit.get("output"))
            if None not in (input_rate, cached_rate, output_rate):
                base = (
                    Decimal(ordinary_for_credits) * input_rate
                    + Decimal(cached) * cached_rate
                    + Decimal(output) * output_rate
                ) / unit
                credit_standard += base
                credit_standard_priced = True
                credit_standard_priced_tokens += usage["total_tokens"]
                tier = segment.get("tier")
                tier_source = segment.get("tier_source")
                if tier_source == "current_config_fallback":
                    credit_configured_complete = False
                    warnings.append("tier came from the current config fallback; no configured-tier price was produced")
                elif tier in STANDARD_TIERS:
                    credit_configured += base
                    credit_configured_priced_tokens += usage["total_tokens"]
                elif tier in FAST_TIERS:
                    fast = credit.get("fast") if isinstance(credit.get("fast"), dict) else {}
                    multiplier = _decimal(fast.get("billing_multiplier"))
                    if multiplier is None:
                        credit_configured_complete = False
                        warnings.append(
                            "Codex Fast billing multiplier was not published for this model; "
                            "the configured-tier credit estimate is incomplete"
                        )
                    else:
                        credit_configured += base * multiplier
                        credit_configured_priced_tokens += usage["total_tokens"]
                else:
                    credit_configured_complete = False
                if cache_write:
                    warnings.append("Codex credits do not publish a separate cache-write rate; ordinary input rate was used")
            else:
                credit_standard_complete = credit_configured_complete = False
        else:
            credit_standard_complete = credit_configured_complete = False
        if not credit_standard_priced:
            credit_unpriced_tokens += usage["total_tokens"]

        api = entry.get("api_usd") if isinstance(entry.get("api_usd"), dict) else None
        if not api:
            api_unpriced_tokens += usage["total_tokens"]
            api_standard_complete = api_configured_complete = False
            continue
        long_context = bool(segment.get("long_context"))
        length_key = "long" if long_context else "short"
        standard_group = api.get("standard") if isinstance(api.get("standard"), dict) else {}
        explicit_long_rates = isinstance(standard_group.get("long"), dict)
        standard_rates = standard_group.get(length_key) or standard_group.get("short")
        if not isinstance(standard_rates, dict):
            api_unpriced_tokens += usage["total_tokens"]
            api_standard_complete = api_configured_complete = False
            continue

        def price_with_rates(rates: Dict[str, Any], long_rule: bool = False) -> Optional[Decimal]:
            input_rate = _decimal(rates.get("input"))
            cached_rate = _decimal(rates.get("cached_input"))
            cache_write_rate = _decimal(rates.get("cache_write"))
            output_rate = _decimal(rates.get("output"))
            if cache_write and cache_write_rate is None:
                warnings.append("API cache-write price was not published for this model; API price is incomplete")
                return None
            if None in (input_rate, cached_rate, output_rate) or (cache_write and cache_write_rate is None):
                return None
            if long_rule:
                rule = api.get("long_context_rule") if isinstance(api.get("long_context_rule"), dict) else {}
                input_multiplier = _decimal(rule.get("input_multiplier")) or Decimal(1)
                output_multiplier = _decimal(rule.get("output_multiplier")) or Decimal(1)
                input_rate *= input_multiplier
                cached_rate *= input_multiplier
                if cache_write_rate is not None:
                    cache_write_rate *= input_multiplier
                output_rate *= output_multiplier
                warnings.append("long-context cached-input API pricing is an estimate for this model")
            return (
                Decimal(ordinary_for_api) * input_rate
                + Decimal(cached) * cached_rate
                + Decimal(cache_write) * (cache_write_rate or Decimal(0))
                + Decimal(output) * output_rate
            ) / unit

        base = price_with_rates(
            standard_rates,
            long_context and not explicit_long_rates and isinstance(api.get("long_context_rule"), dict),
        )
        if base is None:
            api_unpriced_tokens += usage["total_tokens"]
            api_standard_complete = api_configured_complete = False
        else:
            api_standard += base
            api_standard_priced_tokens += usage["total_tokens"]
            tier = segment.get("tier")
            tier_source = segment.get("tier_source")
            if tier_source == "current_config_fallback":
                api_configured_complete = False
                warnings.append("tier came from the current config fallback; no configured-tier price was produced")
            elif tier in STANDARD_TIERS:
                api_configured += base
                api_configured_priced_tokens += usage["total_tokens"]
            elif tier in FAST_TIERS:
                fast_group = api.get("fast") if isinstance(api.get("fast"), dict) else None
                fast_rates = fast_group.get(length_key) if fast_group else None
                if not isinstance(fast_rates, dict):
                    api_configured_complete = False
                    warnings.append(
                        "API Fast pricing was not published for this model; only the Standard equivalent is available"
                    )
                else:
                    fast_value = price_with_rates(fast_rates)
                    if fast_value is None:
                        api_configured_complete = False
                    else:
                        api_configured += fast_value
                        api_configured_priced_tokens += usage["total_tokens"]
            else:
                api_configured_complete = False

    warnings = list(dict.fromkeys(warnings))
    return {
        "catalog_id": catalog.get("catalog_id"),
        "catalog_observed_at": catalog.get("observed_at"),
        "codex_credits_standard_equivalent": _money_text(credit_standard) if credit_standard_complete else None,
        "codex_credits_configured_tier_estimate": (
            _money_text(credit_configured) if credit_configured_complete else None
        ),
        "api_usd_standard_equivalent": _money_text(api_standard) if api_standard_complete else None,
        "api_usd_configured_tier_estimate": _money_text(api_configured) if api_configured_complete else None,
        # Keep the sum of safely priced segments even when another model/tier
        # has no published rate. The hover can then show an explicit lower
        # bound instead of turning a mostly priced task into an opaque dash.
        "codex_credits_standard_priced_subtotal": (
            _money_text(credit_standard) if credit_standard_priced_tokens else None
        ),
        "codex_credits_configured_tier_priced_subtotal": (
            _money_text(credit_configured) if credit_configured_priced_tokens else None
        ),
        "api_usd_standard_priced_subtotal": (
            _money_text(api_standard) if api_standard_priced_tokens else None
        ),
        "api_usd_configured_tier_priced_subtotal": (
            _money_text(api_configured) if api_configured_priced_tokens else None
        ),
        "credit_standard_priced_tokens": credit_standard_priced_tokens,
        "credit_configured_priced_tokens": credit_configured_priced_tokens,
        "api_standard_priced_tokens": api_standard_priced_tokens,
        "api_configured_priced_tokens": api_configured_priced_tokens,
        # Standard-price coverage and configured-tier coverage are different.
        # A model may have a Standard price while its Fast multiplier/rate is
        # unknown, so expose both instead of silently treating the configured
        # subtotal as a complete lower bound.
        "credit_configured_unpriced_tokens": max(
            total_usage_tokens - credit_configured_priced_tokens, 0
        ),
        "api_configured_unpriced_tokens": max(
            total_usage_tokens - api_configured_priced_tokens, 0
        ),
        "effective_tier_confirmed": bool(segments) and all(
            segment.get("tier_source") == "provider_response" for segment in segments
        ),
        "credit_unpriced_tokens": credit_unpriced_tokens,
        "api_unpriced_tokens": api_unpriced_tokens,
        "cost_suppressed": False,
        "warnings": warnings,
    }


def _invalidate_cost(cost: Dict[str, Any], reason: str) -> Dict[str, Any]:
    result = dict(cost)
    result["codex_credits_standard_equivalent"] = None
    result["codex_credits_configured_tier_estimate"] = None
    result["api_usd_standard_equivalent"] = None
    result["api_usd_configured_tier_estimate"] = None
    result["codex_credits_standard_priced_subtotal"] = None
    result["codex_credits_configured_tier_priced_subtotal"] = None
    result["api_usd_standard_priced_subtotal"] = None
    result["api_usd_configured_tier_priced_subtotal"] = None
    result["credit_standard_priced_tokens"] = 0
    result["credit_configured_priced_tokens"] = 0
    result["api_standard_priced_tokens"] = 0
    result["api_configured_priced_tokens"] = 0
    result["cost_suppressed"] = True
    warnings = list(result.get("warnings") or [])
    if reason not in warnings:
        warnings.append(reason)
    result["warnings"] = warnings
    return result


def _apply_current_fallback(turn: Optional[Dict[str, Any]], event: Optional[Dict[str, Any]], defaults: Dict[str, Optional[str]]) -> None:
    if not turn:
        return
    model = turn.get("model") or (event or {}).get("model") or defaults.get("model")
    effort = turn.get("effort") or defaults.get("effort")
    tier = turn.get("tier") or defaults.get("tier")
    if model:
        turn["model"] = model
    if effort:
        turn["effort"] = effort
    if tier and not turn.get("tier"):
        turn["tier"] = tier
        turn["tier_source"] = "current_config_fallback"
    for segment in turn.get("segments", []):
        if not segment.get("model") and model:
            segment["model"] = model
        if not segment.get("effort") and effort:
            segment["effort"] = effort
        if not segment.get("tier") and tier:
            segment["tier"] = tier
            segment["tier_source"] = "current_config_fallback"


def _apply_current_sample_fallback(
    samples: Sequence[Dict[str, Any]], turn: Optional[Dict[str, Any]]
) -> None:
    if not turn:
        return
    task_epoch = _as_int(turn.get("task_epoch"))
    model = turn.get("model")
    effort = turn.get("effort")
    tier = turn.get("tier")
    for sample in samples:
        if _as_int(sample.get("task_epoch")) != task_epoch:
            continue
        if not sample.get("model") and model:
            sample["model"] = model
        if not sample.get("effort") and effort:
            sample["effort"] = effort
        if not sample.get("tier") and tier:
            sample["tier"] = tier
            sample["tier_source"] = "current_config_fallback"


def build_report(
    root_id: str,
    transcript_path: Optional[Path] = None,
    turn_id: Optional[str] = None,
    event: Optional[Dict[str, Any]] = None,
    use_cache: bool = True,
) -> Dict[str, Any]:
    codex_dir = _codex_dir()
    graph_warnings: List[str] = []
    try:
        connection = _connect_state_db(codex_dir)
    except (sqlite3.Error, OSError):
        connection = None
        rows: Dict[str, Dict[str, Any]] = {root_id: {"id": root_id}}
        parent_map: Dict[str, str] = {}
        graph_warnings.append("state database unavailable; subagent totals may be incomplete")
    else:
        try:
            rows, parent_map, graph_warnings = _discover_graph(connection, root_id)
        except sqlite3.Error:
            try:
                root_row = _thread_row(connection, root_id)
            except sqlite3.Error:
                root_row = {}
            rows, parent_map = {root_id: root_row or {"id": root_id}}, {}
            graph_warnings.append("subagent graph query failed; subagent totals may be incomplete")

    rows.setdefault(root_id, {"id": root_id})
    states: Dict[str, Dict[str, Any]] = {}
    thread_paths: Dict[str, Path] = {}
    missing_threads: set[str] = set()

    def parse_known_thread(thread_key: str, row: Dict[str, Any]) -> None:
        path = transcript_path if thread_key == root_id and transcript_path else _resolve_transcript(
            row, thread_key, codex_dir
        )
        if path is None:
            missing_threads.add(thread_key)
            return
        thread_paths[thread_key] = Path(path)
        try:
            states[thread_key] = parse_transcript(Path(path), use_cache=use_cache)
            missing_threads.discard(thread_key)
        except (OSError, ValueError, json.JSONDecodeError):
            missing_threads.add(thread_key)

    for thread_key, row in list(rows.items()):
        parse_known_thread(thread_key, row)

    if root_id not in states and transcript_path:
        parse_known_thread(root_id, rows[root_id])

    if use_cache:
        # One bounded graph refresh catches agents linked while the first
        # snapshot was being read. Then re-read every known transcript
        # incrementally so active descendants get the same tail reconciliation
        # as the root. This remains a best-effort multi-file snapshot.
        if connection is not None:
            try:
                refreshed_rows, refreshed_parents, refreshed_warnings = _discover_graph(connection, root_id)
                new_keys = set(refreshed_rows) - set(rows)
                rows.update(refreshed_rows)
                parent_map.update(refreshed_parents)
                graph_warnings.extend(refreshed_warnings)
                for thread_key in new_keys:
                    parse_known_thread(thread_key, rows[thread_key])
            except sqlite3.Error:
                graph_warnings.append("subagent graph refresh failed; snapshot may omit newly linked agents")
        for thread_key, path in list(thread_paths.items()):
            if thread_key not in states:
                continue
            try:
                states[thread_key] = parse_transcript(path, use_cache=True)
            except (OSError, ValueError, json.JSONDecodeError):
                graph_warnings.append(f"tail reconciliation was unavailable for thread {thread_key}")

    root_state = states.get(root_id)
    if root_state is None:
        if connection is not None:
            connection.close()
        raise RuntimeError("root transcript could not be parsed")
    if root_state.get("thread_id") != root_id:
        if connection is not None:
            connection.close()
        raise RuntimeError("hook session id does not match the transcript's own session_meta")

    # A forked root can contain a copied prefix from an older conversation.
    # Load that parent only to establish the ownership boundary; never add it to
    # this task's totals.
    context_states: Dict[str, Dict[str, Any]] = {}
    root_fork = root_state.get("forked_from_id")
    if isinstance(root_fork, str) and root_fork and root_fork not in states and connection is not None:
        parent_row = _thread_row(connection, root_fork)
        parent_path = _resolve_transcript(parent_row, root_fork, codex_dir)
        if parent_path:
            try:
                context_states[root_fork] = parse_transcript(parent_path, use_cache=use_cache)
            except (OSError, ValueError, json.JSONDecodeError):
                pass

    summaries: Dict[str, Dict[str, Any]] = {}
    for thread_key, state in states.items():
        parent_id = parent_map.get(thread_key)
        if thread_key == root_id and not parent_id:
            parent_id = state.get("forked_from_id")
        parent_state = states.get(parent_id) or context_states.get(parent_id)
        summaries[thread_key] = _thread_summary(
            thread_key,
            state,
            rows.get(thread_key, {}),
            parent_state,
            parent_id,
        )

    defaults = _read_config_defaults(codex_dir)
    root_summary = summaries[root_id]
    root_turns = {turn["turn_id"]: turn for turn in root_summary["turns"]}
    selected_turn = root_turns.get(turn_id) if turn_id else None
    requested_turn_missing = bool(turn_id and selected_turn is None)
    if selected_turn is None and not turn_id and root_summary["turns"]:
        selected_turn = root_summary["turns"][-1]
        turn_id = selected_turn.get("turn_id")
    _apply_current_fallback(selected_turn, event, defaults)
    _apply_current_sample_fallback(root_summary.get("_usage_samples") or [], selected_turn)

    current_window = _turn_time_bounds(selected_turn) if selected_turn else (None, None)
    current_root_turns = [selected_turn] if selected_turn else []
    current_agent_turns: List[Dict[str, Any]] = []
    active_child_ids = set(selected_turn.get("agent_thread_ids") or []) if selected_turn else set()
    active_descendant_ids = set(active_child_ids)
    if active_descendant_ids:
        changed = True
        while changed:
            changed = False
            for child_id, parent_id in parent_map.items():
                if parent_id in active_descendant_ids and child_id not in active_descendant_ids:
                    active_descendant_ids.add(child_id)
                    changed = True
    if selected_turn:
        for thread_key, summary in summaries.items():
            if thread_key == root_id:
                continue
            if active_descendant_ids and thread_key not in active_descendant_ids:
                # Guardian/auto-review threads currently lack a reliable
                # sub_agent_activity link. Include a root-linked no-history
                # agent when its own turn overlaps the selected root window.
                is_unannounced_root_agent = (
                    summary.get("parent_thread_id") == root_id
                    and not summary.get("forked_from_id")
                    and summary.get("thread_source") == "subagent"
                )
                if not is_unannounced_root_agent:
                    continue
            for turn in summary["turns"]:
                if _intervals_overlap(current_window, _turn_time_bounds(turn)):
                    current_agent_turns.append(turn)

    current_turns = current_root_turns + current_agent_turns
    current_usage = _sum_usage(turn.get("usage", {}) for turn in current_turns)
    current_counts = _sum_counts(turn.get("counts", {}) for turn in current_turns)
    current_segments = [segment for turn in current_turns for segment in turn.get("segments", [])]

    root_usage = root_summary["usage"]
    agent_summaries = [summary for key, summary in summaries.items() if key != root_id]
    agents_usage = _sum_usage(summary["usage"] for summary in agent_summaries)
    task_usage = _add_usage(root_usage, agents_usage)
    root_counts = root_summary["counts"]
    agents_counts = _sum_counts(summary["counts"] for summary in agent_summaries)
    task_counts = _add_counts(root_counts, agents_counts)
    task_segments = [segment for summary in summaries.values() for segment in summary["segments"]]
    task_usage_samples = _merge_usage_samples(
        sample
        for summary in summaries.values()
        for sample in (summary.get("_usage_samples") or [])
    )
    task_image_generations = [
        detail
        for summary in summaries.values()
        for detail in (summary.get("_image_generations") or [])
        if isinstance(detail, dict)
    ]
    task_image_generations.sort(
        key=lambda detail: (
            str(detail.get("generated_at") or ""),
            str(detail.get("id") or ""),
        )
    )
    task_rate_limit_snapshots = _merge_rate_limit_snapshots(
        snapshot
        for summary in summaries.values()
        for snapshot in (summary.get("_rate_limit_snapshots") or [])
    )
    task_rate_limit_observations = _merge_rate_limit_observations(
        observation
        for summary in summaries.values()
        for observation in (summary.get("_rate_limit_observations") or [])
    )
    # Do not serialize minute samples beneath thread/turn breakdowns. Those
    # structures intentionally repeat accounting views and would invite double
    # counting by consumers.
    for summary in summaries.values():
        summary.pop("_usage_samples", None)
        summary.pop("_image_generations", None)
        summary.pop("_rate_limit_snapshots", None)
        summary.pop("_rate_limit_observations", None)

    catalog = _load_catalog()
    report_warnings = list(graph_warnings)
    report_warnings.extend(
        warning for summary in summaries.values() for warning in summary.get("warnings", [])
    )
    if missing_threads:
        report_warnings.append(f"{len(missing_threads)} linked thread transcript(s) could not be read")
    if requested_turn_missing:
        report_warnings.append("the requested Stop turn was not yet present; current-turn metrics were left unavailable")
    if any("uuidv7" in str(summary.get("boundary_method")) for summary in summaries.values()):
        report_warnings.append("at least one inherited subagent prefix used a UUIDv7 boundary heuristic")
    if any(summary["parse_errors"] for summary in summaries.values()):
        report_warnings.append("one or more transcript lines could not be parsed")
    if any(_as_int(summary.get("active_turn_count")) for summary in summaries.values()):
        report_warnings.append("one or more task transcripts were still active at the snapshot; totals are provisional")
    if any(summary["counts"]["image_inputs"] for summary in summaries.values()):
        report_warnings.append("image input tokens are included in input_tokens and cannot be separated")
    if any(summary["counts"]["image_generations"] for summary in summaries.values()):
        report_warnings.append("image-generation calls expose no exact token or cost usage in Codex transcripts")

    current_cost = _calculate_cost(current_segments, catalog)
    task_cost = _calculate_cost(task_segments, catalog)
    severe_markers = (
        "counters reset",
        "counters decreased",
        "exceeded",
        "total_tokens !=",
        "reconciliation failed",
        "boundary could not be resolved",
        "baseline exceeded",
    )
    severe_warnings = [
        warning
        for summary in summaries.values()
        for warning in summary.get("warnings", [])
        if any(marker in warning for marker in severe_markers)
    ]
    if severe_warnings:
        reason = "token counter invariants failed; price estimates were suppressed"
        current_cost = _invalidate_cost(current_cost, reason)
        task_cost = _invalidate_cost(task_cost, reason)

    current_provisional = bool(
        selected_turn
        and any(not turn.get("completed_at") and not turn.get("aborted") for turn in current_turns)
    )
    task_usage_is_lower_bound = bool(
        requested_turn_missing
        or missing_threads
        or graph_warnings
        or severe_warnings
        or any(summary.get("parse_errors") for summary in summaries.values())
        or any(_as_int(summary.get("active_turn_count")) for summary in summaries.values())
        or any(not summary.get("exclusive_usage_available", True) for summary in summaries.values())
    )

    report = {
        "report_schema_version": REPORT_SCHEMA_VERSION,
        "generated_at": _now_iso(),
        "root_thread_id": root_id,
        "selected_turn_id": turn_id,
        "image_generations": task_image_generations,
        "rate_limit_snapshots": task_rate_limit_snapshots,
        "rate_limit_observations": task_rate_limit_observations,
        "current_turn": {
            "available": selected_turn is not None,
            "usage_is_provisional": current_provisional,
            "usage": current_usage,
            "counts": current_counts,
            "root_usage": _sum_usage(turn.get("usage", {}) for turn in current_root_turns),
            "agents_usage": _sum_usage(turn.get("usage", {}) for turn in current_agent_turns),
            "segments": current_segments,
            "cost": current_cost,
            "duration_ms": selected_turn.get("duration_ms") if selected_turn else None,
            "ttft_ms": selected_turn.get("ttft_ms") if selected_turn else None,
        },
        "task": {
            "usage": task_usage,
            "counts": task_counts,
            "root_usage": root_usage,
            "agents_usage": agents_usage,
            "segments": task_segments,
            "usage_samples": task_usage_samples,
            "cost": task_cost,
            "linked_agent_threads": len(agent_summaries),
            "usage_is_lower_bound": task_usage_is_lower_bound,
        },
        "threads": list(summaries.values()),
        "completeness": {
            "text_token_breakdown": "observed_current_codex_transcript",
            "image_token_breakdown": "unavailable_folded_into_input",
            "effective_service_tier": "requested_or_observed_setting_not_provider_confirmation",
            "subscription_dollars": "unavailable_api_equivalent_only",
            "subagent_attribution": "linked_graph_plus_source_metadata",
            "all_agent_per_turn": "activity_link_plus_time_window_estimate",
            "snapshot_consistency": "best_effort_two_pass_not_transactional_across_files",
            "usage_summary": "lower_bound" if task_usage_is_lower_bound else "complete_observed_snapshot",
        },
        "warnings": list(dict.fromkeys(report_warnings)),
        "pricing_catalog": {
            "catalog_id": catalog.get("catalog_id"),
            "observed_at": catalog.get("observed_at"),
            "scope": catalog.get("scope"),
            "sources": catalog.get("sources"),
        },
    }
    if connection is not None:
        connection.close()
    return report


def _fmt_tokens(value: Any) -> str:
    number = _as_int(value)
    if number >= 1_000_000_000:
        return f"{number / 1_000_000_000:.2f}B"
    if number >= 1_000_000:
        return f"{number / 1_000_000:.2f}M"
    if number >= 1_000:
        return f"{number / 1_000:.1f}k"
    return str(number)


def _fmt_decimal(value: Any, suffix: str = "") -> str:
    decimal_value = _decimal(value)
    if decimal_value is None:
        return "—"
    if abs(decimal_value) >= Decimal("100"):
        text = f"{decimal_value:.1f}"
    elif abs(decimal_value) >= Decimal("1"):
        text = f"{decimal_value:.3f}"
    else:
        text = f"{decimal_value:.6f}"
    return text.rstrip("0").rstrip(".") + suffix


def _cost_text(cost: Dict[str, Any], configured_key: str, standard_key: str, suffix: str) -> str:
    configured = cost.get(configured_key)
    standard = cost.get(standard_key)
    if configured is not None:
        configured_text = _fmt_decimal(configured, suffix)
        if standard is not None and _decimal(configured) != _decimal(standard):
            return f"按设置档位 {configured_text}（Standard基准 {_fmt_decimal(standard, suffix)}）"
        return "按设置档位 " + configured_text
    if standard is not None:
        return "Standard基准 " + _fmt_decimal(standard, suffix)
    return "—"


def _segment_labels(segments: Sequence[Dict[str, Any]], catalog: Dict[str, Any]) -> str:
    labels: List[str] = []
    for segment in segments:
        if not _usage_from(segment.get("usage"))["total_tokens"]:
            continue
        _, entry = _model_entry(catalog, segment.get("model"))
        model = entry.get("display_name") if entry else segment.get("model") or "模型未知"
        effort = segment.get("effort") or "effort未知"
        tier = segment.get("tier")
        tier_source = segment.get("tier_source")
        source_text = {
            "provider_response": "服务端确认",
            "thread_settings": "线程设置",
            "current_config_fallback": "按当前配置推断",
        }.get(tier_source, "来源未知")
        if tier in FAST_TIERS:
            speed = None
            if entry:
                speed = entry.get("codex_credits", {}).get("fast", {}).get("speed_multiplier_nominal")
            tier_text = f"Fast {speed or '?'}×（{source_text}）"
        elif tier in STANDARD_TIERS:
            tier_text = f"Standard 1.0×（{source_text}）"
        else:
            tier_text = "速度档未知"
        label = f"{model} · {effort} · {tier_text}"
        if label not in labels:
            labels.append(label)
    if not labels:
        return "模型/速度档未知"
    if len(labels) <= 2:
        return "；".join(labels)
    return f"混合模型/档位（{len(labels)} 种）"


def _segment_usage_labels(
    segments: Sequence[Dict[str, Any]], catalog: Dict[str, Any]
) -> List[Tuple[str, int]]:
    """Group priced segments into readable model/tier rows for the UI tip."""
    grouped: Dict[str, int] = {}
    for segment in segments:
        segment_usage = _usage_from(segment.get("usage"))
        if not segment_usage["total_tokens"]:
            continue
        label = _segment_labels([segment], catalog)
        grouped[label] = grouped.get(label, 0) + segment_usage["total_tokens"]
    return list(grouped.items())


def _model_tip_lines(
    segments: Sequence[Dict[str, Any]], catalog: Dict[str, Any], max_rows: int = 6
) -> List[str]:
    groups = _segment_usage_labels(segments, catalog)
    if not groups:
        return ["  模型  模型/速度档未知"]
    if len(groups) == 1:
        return [f"  模型  {groups[0][0]}"]
    lines = [f"  模型  混合 {len(groups)} 种"]
    for label, token_total in groups[:max_rows]:
        lines.append(f"        {_fmt_tokens(token_total)} · {label}")
    if len(groups) > max_rows:
        lines.append(f"        …另有 {len(groups) - max_rows} 种")
    return lines


def _usage_tip_lines(usage: Dict[str, int]) -> List[str]:
    input_tokens = _as_int(usage.get("input_tokens"))
    cached_tokens = _as_int(usage.get("cached_input_tokens"))
    cache_write_tokens = _as_int(usage.get("cache_write_input_tokens"))
    ordinary_tokens = max(input_tokens - cached_tokens - cache_write_tokens, 0)
    return [
        f"  输入  {_fmt_tokens(input_tokens)}（普通 {_fmt_tokens(ordinary_tokens)} · "
        f"缓存读 {_fmt_tokens(cached_tokens)} · 缓存写 {_fmt_tokens(cache_write_tokens)}）",
        f"  输出  {_fmt_tokens(_as_int(usage.get('output_tokens')))}"
        f"（其中推理 {_fmt_tokens(_as_int(usage.get('reasoning_output_tokens')))}）",
    ]


def _estimate_tip_line(
    cost: Dict[str, Any], provisional: bool = False
) -> str:
    credit = _cost_text(
        cost,
        "codex_credits_configured_tier_estimate",
        "codex_credits_standard_equivalent",
        " credits",
    )
    usd = _cost_text(
        cost,
        "api_usd_configured_tier_estimate",
        "api_usd_standard_equivalent",
        " USD",
    )
    scope = "已观测部分" if provisional else "估算"
    return f"  费用  {scope}：Codex {credit} · API 等价 {usd}"


def _image_tip_line(counts: Dict[str, Any]) -> Optional[str]:
    image_inputs = _as_int(counts.get("image_inputs"))
    image_generations = _as_int(counts.get("image_generations"))
    if not image_inputs and not image_generations:
        return None
    return (
        f"  图片  输入 {image_inputs} 次（token 已含在输入、不可单拆） · "
        f"生成 {image_generations} 次"
    )


def _hover_model_text(segments: Sequence[Dict[str, Any]], catalog: Dict[str, Any]) -> str:
    groups = _segment_usage_labels(segments, catalog)
    if not groups:
        return "模型/速度档未知"
    if len(groups) > 1:
        return f"混合 {len(groups)} 种模型/档位"
    return (
        groups[0][0]
        .replace(" · ", "·")
        .replace("Standard 1.0×", "Std1×")
        .replace("Fast 1.5×", "Fast1.5×")
        .replace("（按当前配置推断）", "(推)")
        .replace("（线程设置）", "")
        .replace("（服务端确认）", "")
        .replace("（来源未知）", "")
    )


def _hover_cost_value(cost: Dict[str, Any], configured_key: str, standard_key: str) -> str:
    configured = cost.get(configured_key)
    value = configured if configured is not None else cost.get(standard_key)
    return _hover_decimal_value(value)


def _hover_decimal_value(value: Any) -> str:
    decimal_value = _decimal(value)
    if decimal_value is None:
        return "—"
    if decimal_value == 0:
        return "0"
    absolute = abs(decimal_value)
    if absolute >= Decimal("100"):
        text = f"{decimal_value:.0f}"
    elif absolute >= Decimal("10"):
        text = f"{decimal_value:.1f}"
    elif absolute >= Decimal("1"):
        text = f"{decimal_value:.2f}"
    elif absolute >= Decimal("0.01"):
        text = f"{decimal_value:.4f}"
    elif absolute and absolute < Decimal("0.0001"):
        return "<0.0001"
    else:
        text = f"{decimal_value:.6f}"
    return text.rstrip("0").rstrip(".") if "." in text else text


def _fmt_hover_tokens(value: Any) -> str:
    number = _as_int(value)
    if number >= 1_000_000_000:
        return f"{number / 1_000_000_000:.1f}B"
    if number >= 1_000_000:
        return f"{number / 1_000_000:.1f}M"
    if number >= 1_000:
        return f"{number / 1_000:.1f}k"
    return str(number)


def _fmt_hover_tokens_tiny(value: Any) -> str:
    """Compact rounded counters for the three-part anti-flicker hover."""
    number = _as_int(value)
    if number >= 1_000_000_000:
        precision = 0 if number >= 100_000_000_000 else 1
        return f"{number / 1_000_000_000:.{precision}f}B"
    if number >= 1_000_000:
        precision = 0 if number >= 100_000_000 else 1
        return f"{number / 1_000_000:.{precision}f}M"
    if number >= 1_000:
        precision = 0 if number >= 100_000 else 1
        return f"{number / 1_000:.{precision}f}k"
    return str(number)


def _hover_usage_line(label: str, usage: Dict[str, int], provisional: bool) -> str:
    input_tokens = _as_int(usage.get("input_tokens"))
    cached_tokens = _as_int(usage.get("cached_input_tokens"))
    cache_write_tokens = _as_int(usage.get("cache_write_input_tokens"))
    prefix = "≥" if provisional else ""
    state = "暂" if label == "本轮" and provisional else "下界" if provisional else ""
    return (
        f"{label}{prefix}{_fmt_hover_tokens(_as_int(usage.get('total_tokens')))}{state}｜"
        f"入{_fmt_hover_tokens(input_tokens)}/缓{_fmt_hover_tokens(cached_tokens)}/"
        f"写{_fmt_hover_tokens(cache_write_tokens)}｜"
        f"出{_fmt_hover_tokens(_as_int(usage.get('output_tokens')))}/"
        f"推{_fmt_hover_tokens(_as_int(usage.get('reasoning_output_tokens')))}"
    )


def _hover_cost_pair(cost: Dict[str, Any]) -> str:
    credit = _hover_cost_value(
        cost,
        "codex_credits_configured_tier_estimate",
        "codex_credits_standard_equivalent",
    )
    usd = _hover_cost_value(
        cost,
        "api_usd_configured_tier_estimate",
        "api_usd_standard_equivalent",
    )
    if credit == "—" and usd == "—":
        return "—"
    credit_text = "—" if credit == "—" else credit + "cr"
    usd_text = "—" if usd == "—" else "$" + usd
    return f"{credit_text}/{usd_text}"


def _display_cells(text: str) -> int:
    return sum(
        0 if char == WORD_JOINER else 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        for char in text
    )


def _clip_display_cells(text: str, limit: int = 64) -> str:
    if _display_cells(text) <= limit:
        return text
    output: List[str] = []
    used = 0
    for char in text:
        width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        if used + width > limit - 1:
            break
        output.append(char)
        used += width
    return "".join(output) + "…"


def _clip_utf8_bytes(text: str, limit: int = 100) -> str:
    if len(text.encode("utf-8")) <= limit:
        return text
    ellipsis = "…"
    budget = limit - len(ellipsis.encode("utf-8"))
    output: List[str] = []
    used = 0
    for char in text:
        width = len(char.encode("utf-8"))
        if used + width > budget:
            break
        output.append(char)
        used += width
    return "".join(output) + ellipsis


def _compact_cost_notes(current_cost: Dict[str, Any], task_cost: Dict[str, Any]) -> List[str]:
    cost_warnings = list(current_cost.get("warnings") or []) + list(task_cost.get("warnings") or [])
    notes: List[str] = []
    if any("source conflict" in warning for warning in cost_warnings):
        notes.append("官方价目冲突，采用总价目页")
    if any("API Fast pricing was not published" in warning for warning in cost_warnings):
        notes.append("API Fast 同档价未公布")
    if any("current config fallback" in warning for warning in cost_warnings):
        notes.append("档位仅按当前配置推断")
    if _as_int(task_cost.get("credit_unpriced_tokens")) or _as_int(task_cost.get("api_unpriced_tokens")):
        notes.append("部分 token 无公开价目")
    return notes


def _short_hover_model_name(model: Any, entry: Optional[Dict[str, Any]]) -> str:
    value = entry.get("display_name") if entry else model
    text = str(value or "未知")
    if text == "codex-auto-review":
        return "AutoReview"
    text = text.replace("GPT-", "").replace(" ", "")
    return _clip_display_cells(text, 12)


def _hover_model_multiplier_rows(
    segments: Sequence[Dict[str, Any]], catalog: Dict[str, Any]
) -> Tuple[str, str]:
    models: List[str] = []
    model_ids: set[str] = set()
    speeds: List[str] = []
    billing: List[str] = []
    efforts: List[str] = []
    groups = _segment_usage_labels(segments, catalog)
    for segment in segments:
        if not _usage_from(segment.get("usage"))["total_tokens"]:
            continue
        model_key, entry = _model_entry(catalog, segment.get("model"))
        model = _short_hover_model_name(segment.get("model"), entry)
        model_identity = model_key or str(segment.get("model") or "未知")
        if model_identity not in model_ids:
            model_ids.add(model_identity)
            models.append(model)
        effort = str(segment.get("effort") or "?")
        if effort not in efforts:
            efforts.append(effort)
        tier = segment.get("tier")
        if tier in STANDARD_TIERS:
            speed_text = "1×"
            billing_text = "1×"
        elif tier in FAST_TIERS:
            fast = entry.get("codex_credits", {}).get("fast", {}) if entry else {}
            speed = _decimal(fast.get("speed_multiplier_nominal"))
            multiplier = _decimal(fast.get("billing_multiplier"))
            speed_text = (_hover_decimal_value(speed) + "×") if speed is not None else "?"
            billing_text = (_hover_decimal_value(multiplier) + "×") if multiplier is not None else "?"
        else:
            speed_text = billing_text = "?"
        if speed_text not in speeds:
            speeds.append(speed_text)
        if billing_text not in billing:
            billing.append(billing_text)

    if not models:
        return "模型/档位未知", "倍率速度?·额度?"
    if len(models) <= 2:
        model_text = "+".join(models)
    else:
        model_text = f"混合{len(models)}模型"
    group_suffix = f"·{len(groups)}档" if len(groups) > 1 else ""
    effort_suffix = f"·{efforts[0]}" if len(efforts) == 1 else ""
    def multiplier_order(value: str) -> Tuple[int, Decimal]:
        number = _decimal(value.removesuffix("×"))
        return (1, Decimal(0)) if number is None else (0, number)

    speeds.sort(key=multiplier_order)
    billing.sort(key=multiplier_order)
    model_row = f"模型{model_text}{group_suffix}{effort_suffix}"
    multiplier_row = f"倍率速度{'/'.join(speeds)}·额度{'/'.join(billing)}"
    return model_row, multiplier_row


def _hover_price_component(
    cost: Dict[str, Any], *, kind: str, lower_bound: bool
) -> str:
    if kind == "credit":
        label = "额度"
        suffix = "cr"
        configured_exact_key = "codex_credits_configured_tier_estimate"
        configured_partial_key = "codex_credits_configured_tier_priced_subtotal"
        standard_exact_key = "codex_credits_standard_equivalent"
        standard_partial_key = "codex_credits_standard_priced_subtotal"
    else:
        label = "API"
        suffix = ""
        configured_exact_key = "api_usd_configured_tier_estimate"
        configured_partial_key = "api_usd_configured_tier_priced_subtotal"
        standard_exact_key = "api_usd_standard_equivalent"
        standard_partial_key = "api_usd_standard_priced_subtotal"

    # These values are rounded for display, so do not use a strict >= marker.
    # "已观测" describes an active snapshot; "已定价" describes a subtotal
    # whose remaining model/tier has no published configured price.
    candidates = (
        (cost.get(configured_exact_key), "已观测≈" if lower_bound else "≈"),
        (cost.get(configured_partial_key), "已定价≈"),
        (cost.get(standard_exact_key), "Std已观测≈" if lower_bound else "Std≈"),
        (cost.get(standard_partial_key), "Std已定价≈"),
    )
    for value, marker in candidates:
        if value is None:
            continue
        number = _hover_decimal_value(value)
        prefix = "$" if kind == "api" else ""
        return f"{label}{marker}{prefix}{number}{suffix}"
    return f"{label}—"


def _atomic_hover_row(text: str, limit: int = 40) -> str:
    """Keep one short semantic row intact inside the Desktop break-words span."""
    safe_text = "".join(
        char
        for char in text
        if not unicodedata.category(char).startswith("C")
        and unicodedata.category(char) not in ("Zl", "Zp")
    ).replace(" ", "")
    clipped = _clip_display_cells(safe_text, limit)
    return WORD_JOINER.join(clipped)


def _plain_hover_part(text: str, limit: int = 38) -> str:
    """Sanitize and bound a short part without making it unbreakable."""
    safe_text = "".join(
        char
        for char in text
        if not unicodedata.category(char).startswith("C")
        and unicodedata.category(char) not in ("Zl", "Zp")
    ).replace(" ", "")
    return _clip_display_cells(safe_text, limit)


def _hover_credit_number(value: Any) -> str:
    decimal_value = _decimal(value)
    if decimal_value is None:
        return "—"
    absolute = abs(decimal_value)
    if absolute == 0:
        text = "0"
    elif absolute < Decimal("0.001"):
        text = "<.001"
    elif absolute < Decimal("0.1"):
        text = f"{decimal_value:.3f}".rstrip("0").rstrip(".")
    elif absolute < Decimal("1"):
        text = f"{decimal_value:.2f}".rstrip("0").rstrip(".")
    else:
        text = _hover_decimal_value(decimal_value)
    if text.startswith("0."):
        return text[1:]
    if text.startswith("-0."):
        return "-." + text[3:]
    return text


def _hover_credit_pair(
    current_cost: Dict[str, Any], task_cost: Dict[str, Any]
) -> Tuple[str, str, str]:
    """Choose one comparable price basis for current-turn/task credits."""
    configured_exact = "codex_credits_configured_tier_estimate"
    standard_exact = "codex_credits_standard_equivalent"
    configured_partial = "codex_credits_configured_tier_priced_subtotal"
    standard_partial = "codex_credits_standard_priced_subtotal"

    def present(cost: Dict[str, Any], key: str) -> bool:
        return _decimal(cost.get(key)) is not None

    def pair(key: str, label: str) -> Tuple[str, str, str]:
        return (
            _hover_credit_number(current_cost.get(key)),
            _hover_credit_number(task_cost.get(key)),
            label,
        )

    # Exact, directly comparable values are preferable even when that means
    # using the explicitly labelled Standard equivalent instead of an
    # incomplete configured-tier subtotal.
    if present(current_cost, configured_exact) and present(task_cost, configured_exact):
        return pair(configured_exact, "价≈")
    if present(current_cost, standard_exact) and present(task_cost, standard_exact):
        return pair(standard_exact, "Std价≈")

    for exact_key, partial_key, label in (
        (configured_exact, configured_partial, "部价≈"),
        (standard_exact, standard_partial, "Std部价≈"),
    ):
        current_key = exact_key if present(current_cost, exact_key) else partial_key
        task_key = exact_key if present(task_cost, exact_key) else partial_key
        if present(current_cost, current_key) and present(task_cost, task_key):
            return (
                _hover_credit_number(current_cost.get(current_key)),
                _hover_credit_number(task_cost.get(task_key)),
                label,
            )

    # If one scope is unavailable, retain a truthful value for the other but
    # never compare two values derived from different price bases.
    for key, label in (
        (configured_exact, "价≈"),
        (standard_exact, "Std价≈"),
        (configured_partial, "部价≈"),
        (standard_partial, "Std部价≈"),
    ):
        current_present = present(current_cost, key)
        task_present = present(task_cost, key)
        if current_present != task_present:
            other_cost = task_cost if current_present else current_cost
            if not any(
                present(other_cost, candidate)
                for candidate in (
                    configured_exact,
                    standard_exact,
                    configured_partial,
                    standard_partial,
                )
            ):
                return pair(key, label)
    return "—", "—", "价"


def _hover_short_model_multiplier(
    segments: Sequence[Dict[str, Any]], catalog: Dict[str, Any]
) -> str:
    _, multiplier_row = _hover_model_multiplier_rows(segments, catalog)
    model_names: List[str] = []
    for segment in segments:
        if not _usage_from(segment.get("usage"))["total_tokens"]:
            continue
        _, entry = _model_entry(catalog, segment.get("model"))
        name = _short_hover_model_name(segment.get("model"), entry)
        name = {
            "AutoReview": "A",
            "5.6Sol": "5.6S",
            "5.6Terra": "5.6T",
            "5.6Luna": "5.6L",
        }.get(name, name)
        if name not in model_names:
            model_names.append(name)
    if not model_names:
        model_text = "模?"
    elif len(model_names) <= 2:
        model_text = "+".join(model_names)
    else:
        model_text = f"混{len(model_names)}模"

    multiplier_value = multiplier_row.removeprefix("倍率速度")
    speed_value, separator, billing_value = multiplier_value.partition("·额度")
    if not separator:
        speed_value = billing_value = "?"

    def values(text: str) -> str:
        return "/".join(value.removesuffix("×") for value in text.split("/"))

    return f"速×{values(speed_value)}·额×{values(billing_value)}·{model_text}"


def _hover_scope_rows(
    label: str,
    section: Dict[str, Any],
    catalog: Dict[str, Any],
    *,
    lower_bound: bool,
    agent_count: Optional[int] = None,
) -> List[str]:
    usage = _usage_from(section.get("usage"))
    root = _usage_from(section.get("root_usage"))
    agents = _usage_from(section.get("agents_usage"))
    state = "暂计" if label == "本轮" and lower_bound else "已观测" if lower_bound else ""
    total_row = (
        f"【{label}】{state}{_fmt_hover_tokens(usage['total_tokens'])}"
        f"·主{_fmt_hover_tokens(root['total_tokens'])}"
        f"·代理{_fmt_hover_tokens(agents['total_tokens'])}"
    )
    ordinary_input = max(
        usage["input_tokens"]
        - usage["cached_input_tokens"]
        - usage["cache_write_input_tokens"],
        0,
    )
    input_row = (
        f"输入{_fmt_hover_tokens(usage['input_tokens'])}"
        f"·普通{_fmt_hover_tokens(ordinary_input)}"
        f"·缓存读{_fmt_hover_tokens(usage['cached_input_tokens'])}"
        f"·缓存写{_fmt_hover_tokens(usage['cache_write_input_tokens'])}"
    )
    counts = section.get("counts") or {}
    output_row = (
        f"输出{_fmt_hover_tokens(usage['output_tokens'])}"
        f"·推理{_fmt_hover_tokens(usage['reasoning_output_tokens'])}"
        f"·图入{_as_int(counts.get('image_inputs'))}"
        f"·图生{_as_int(counts.get('image_generations'))}"
    )
    model_row, multiplier_row = _hover_model_multiplier_rows(section.get("segments") or [], catalog)
    if agent_count:
        model_row += f"·代理{agent_count}个"
    cost = section.get("cost") or {}
    price_row = (
        "价格·"
        + _hover_price_component(cost, kind="credit", lower_bound=lower_bound)
        + "·"
        + _hover_price_component(cost, kind="api", lower_bound=lower_bound)
    )
    return [total_row, input_row, output_row, model_row, multiplier_row, price_row]


def _hover_note_rows(report: Dict[str, Any]) -> List[str]:
    current = report["current_turn"]
    task = report["task"]
    current_cost = current.get("cost") or {}
    task_cost = task.get("cost") or {}
    suppressed = bool(current_cost.get("cost_suppressed") or task_cost.get("cost_suppressed"))
    rows = (
        ["【价格备注】计数校验失败·价格已抑制"]
        if suppressed
        else ["【价格备注】公开价估算·API等价非账单"]
    )

    def configured_gap(cost: Dict[str, Any], kind: str) -> int:
        key = f"{kind}_configured_unpriced_tokens"
        legacy_key = f"{kind}_unpriced_tokens"
        return _as_int(cost.get(key) if key in cost else cost.get(legacy_key))

    def standard_gap(cost: Dict[str, Any], kind: str) -> int:
        return _as_int(cost.get(f"{kind}_unpriced_tokens"))

    def append_gap_rows(
        prefix: str,
        current_credit: int,
        task_credit: int,
        current_api: int,
        task_api: int,
    ) -> None:
        if not (current_credit or task_credit or current_api or task_api):
            return
        if (current_credit, task_credit) == (current_api, task_api):
            rows.append(
                f"{prefix}·轮{_fmt_hover_tokens(current_credit)}"
                f"·会{_fmt_hover_tokens(task_credit)}（额/API）"
            )
            return
        if current_credit or task_credit:
            rows.append(
                f"{prefix}·额度轮{_fmt_hover_tokens(current_credit)}"
                f"·会{_fmt_hover_tokens(task_credit)}"
            )
        if current_api or task_api:
            rows.append(
                f"{prefix}·API轮{_fmt_hover_tokens(current_api)}"
                f"·会{_fmt_hover_tokens(task_api)}"
            )

    current_credit_standard_gap = standard_gap(current_cost, "credit")
    task_credit_standard_gap = standard_gap(task_cost, "credit")
    current_api_standard_gap = standard_gap(current_cost, "api")
    task_api_standard_gap = standard_gap(task_cost, "api")
    current_credit_gap = configured_gap(current_cost, "credit")
    task_credit_gap = configured_gap(task_cost, "credit")
    current_api_gap = configured_gap(current_cost, "api")
    task_api_gap = configured_gap(task_cost, "api")
    if not suppressed:
        append_gap_rows(
            "公开价缺失",
            current_credit_standard_gap,
            task_credit_standard_gap,
            current_api_standard_gap,
            task_api_standard_gap,
        )
        append_gap_rows(
            "设置档缺价",
            max(current_credit_gap - current_credit_standard_gap, 0),
            max(task_credit_gap - task_credit_standard_gap, 0),
            max(current_api_gap - current_api_standard_gap, 0),
            max(task_api_gap - task_api_standard_gap, 0),
        )

    segments = list(current.get("segments") or []) + list(task.get("segments") or [])
    sources = {
        segment.get("tier_source")
        for segment in segments
        if _usage_from(segment.get("usage"))["total_tokens"]
    }
    if "current_config_fallback" in sources:
        rows.append("档位：按当前配置推断")
    elif None in sources:
        rows.append("档位：部分速度档来源未知")
    elif "thread_settings" in sources:
        rows.append("档位：按线程设置估算")

    warnings = list(current_cost.get("warnings") or []) + list(task_cost.get("warnings") or [])
    if any("source conflict" in warning for warning in warnings):
        rows.append("价目冲突采用官方总价表")
    if any("Fast pricing was not published" in warning for warning in warnings):
        rows.append("部分Fast API价格未公开")
    if any("Fast billing multiplier was not published" in warning for warning in warnings):
        rows.append("部分Fast额度倍率未公开")
    if any("cache-write" in warning for warning in warnings):
        rows.append("缓存写价格按公开规则估算")
    if not suppressed and any("counter invariants failed" in warning for warning in warnings):
        rows.append("计数校验失败·价格已抑制")
    return list(dict.fromkeys(rows))


def format_hover(report: Dict[str, Any]) -> str:
    """At most three short, freely wrapping parts for Desktop's Hook tooltip.

    The action row (including its timestamp) is itself hover-gated. A tall
    tooltip can cover that trigger and create an open/close feedback loop, so
    full details belong in latest.txt/json rather than systemMessage.
    """
    current = report["current_turn"]
    task = report["task"]
    catalog = _load_catalog()
    task_usage = _usage_from(task.get("usage"))
    current_available = current.get("available") is not False
    current_usage = _usage_from(current.get("usage"))
    counts = current.get("counts") or {}

    current_marker = "暂" if current_available and current.get("usage_is_provisional") else ""
    task_marker = "观" if task.get("usage_is_lower_bound") else ""
    current_total = (
        _fmt_hover_tokens_tiny(current_usage["total_tokens"])
        if current_available
        else "不可用"
    )
    totals_part = (
        f"轮{current_marker}{current_total}"
        f"·会{task_marker}{_fmt_hover_tokens_tiny(task_usage['total_tokens'])}"
        + (
            f"·图{_as_int(counts.get('image_inputs'))}/{_as_int(counts.get('image_generations'))}"
            if current_available
            else "·图—/—"
        )
    )

    if current_available:
        usage_part = (
            f"入{_fmt_hover_tokens_tiny(current_usage['input_tokens'])}"
            f"/缓{_fmt_hover_tokens_tiny(current_usage['cached_input_tokens'])}"
            f"/写{_fmt_hover_tokens_tiny(current_usage['cache_write_input_tokens'])}"
            f"·出{_fmt_hover_tokens_tiny(current_usage['output_tokens'])}"
            f"/推{_fmt_hover_tokens_tiny(current_usage['reasoning_output_tokens'])}"
        )
    else:
        usage_part = "本轮明细不可用"

    current_credit, task_credit, price_label = _hover_credit_pair(
        current.get("cost") or {}, task.get("cost") or {}
    )
    model_price_part = (
        f"{price_label}{current_credit}/{task_credit}cr"
        f"·{_hover_short_model_multiplier(task.get('segments') or [], catalog)}"
    )

    parts = [
        _plain_hover_part(totals_part),
        _plain_hover_part(usage_part),
        _plain_hover_part(model_price_part),
    ]
    # STEPS_COMMANDS collapses newlines, so separators are deliberate plain
    # break opportunities. Avoid WORD JOINER: narrow windows must be able to
    # reflow instead of overflowing back onto the trigger.
    return " | ".join(parts)


def format_compact(report: Dict[str, Any]) -> str:
    current = report["current_turn"]
    task = report["task"]
    current_usage = _usage_from(current.get("usage"))
    current_root_usage = _usage_from(current.get("root_usage"))
    current_agents_usage = _usage_from(current.get("agents_usage"))
    task_usage = _usage_from(task.get("usage"))
    root_usage = _usage_from(task.get("root_usage"))
    agents_usage = _usage_from(task.get("agents_usage"))
    current_cost = current.get("cost") or {}
    task_cost = task.get("cost") or {}
    catalog = _load_catalog()
    duration = current.get("duration_ms")
    ttft = current.get("ttft_ms")
    time_bits = []
    if duration:
        time_bits.append(f"耗时 {duration / 1000:.1f}s")
    if ttft:
        time_bits.append(f"TTFT {ttft / 1000:.1f}s")
    time_text = " · ".join(time_bits)
    current_counts = current.get("counts") or {}
    counts = task.get("counts") or {}
    lines = ["Codex Token 用量", "", "本轮对话"]
    if current.get("available") is False:
        lines.append("  状态  暂不可用：Stop 快照尚未写入本轮；不会拿上一轮冒充")
    else:
        current_provisional = bool(current.get("usage_is_provisional"))
        current_prefix = "已观测约 " if current_provisional else ""
        current_status = " · 暂定" if current_provisional else ""
        lines.append(
            f"  总计  {current_prefix}{_fmt_tokens(current_usage['total_tokens'])} tokens{current_status}"
        )
        lines.append(
            f"  构成  主对话 {_fmt_tokens(current_root_usage['total_tokens'])} · "
            f"子代理 {_fmt_tokens(current_agents_usage['total_tokens'])}"
        )
        lines.extend(_usage_tip_lines(current_usage))
        lines.extend(_model_tip_lines(current.get("segments") or [], catalog))
        lines.append(_estimate_tip_line(current_cost, provisional=current_provisional))
        current_image_line = _image_tip_line(current_counts)
        if current_image_line:
            lines.append(current_image_line)
        if time_text:
            lines.append(f"  性能  {time_text}")

    task_lower_bound = bool(task.get("usage_is_lower_bound"))
    task_prefix = "已观测约 " if task_lower_bound else ""
    task_status = " · 当前快照下界" if task_lower_bound else ""
    lines.extend(
        [
            "",
            "整个会话",
            f"  总计  {task_prefix}{_fmt_tokens(task_usage['total_tokens'])} tokens{task_status}",
            f"  构成  主对话 {_fmt_tokens(root_usage['total_tokens'])} · 子代理 "
            f"{_fmt_tokens(agents_usage['total_tokens'])}（{task.get('linked_agent_threads', 0)} 个）",
        ]
    )
    lines.extend(_usage_tip_lines(task_usage))
    lines.extend(_model_tip_lines(task.get("segments") or [], catalog))
    lines.append(_estimate_tip_line(task_cost, provisional=task_lower_bound))
    task_image_line = _image_tip_line(counts)
    if task_image_line:
        lines.append(task_image_line)
    compact_notes = _compact_cost_notes(current_cost, task_cost)
    if compact_notes:
        lines.extend(["", "注意"])
        lines.extend(f"  ⚠ {note}" for note in compact_notes)
    return "\n".join(lines)


def format_full(report: Dict[str, Any]) -> str:
    lines = [format_compact(report), "", "明细"]
    task = report["task"]
    usage = _usage_from(task.get("usage"))
    lines.extend(
        [
            f"  Input              {_fmt_tokens(usage['input_tokens'])}",
            f"  Cached input       {_fmt_tokens(usage['cached_input_tokens'])}  (Input 子集)",
            f"  Cache-write input  {_fmt_tokens(usage['cache_write_input_tokens'])}  (Input 子集)",
            f"  Output             {_fmt_tokens(usage['output_tokens'])}",
            f"  Reasoning output   {_fmt_tokens(usage['reasoning_output_tokens'])}  (Output 子集)",
            f"  Total              {_fmt_tokens(usage['total_tokens'])}  (= Input + Output)",
            "",
            "线程（已扣除 fork/subagent 继承的上下文前缀）",
        ]
    )
    for thread in report.get("threads", []):
        thread_usage = _usage_from(thread.get("usage"))
        agent = thread.get("agent_path") or "root"
        inherited = _usage_from(thread.get("inherited_prefix_usage"))["total_tokens"]
        lines.append(
            f"  {agent}: {_fmt_tokens(thread_usage['total_tokens'])} exclusive"
            f" · inherited {_fmt_tokens(inherited)} · {thread.get('boundary_method')}"
        )
    counts = task.get("counts") or {}
    lines.extend(
        [
            "",
            "模态/工具计数",
            f"  图片输入 {_as_int(counts.get('image_inputs'))}；图片生成 {_as_int(counts.get('image_generations'))}；"
            f"音频输入 {_as_int(counts.get('audio_inputs'))}",
            f"  Web search {_as_int(counts.get('web_searches'))}；MCP {_as_int(counts.get('mcp_calls'))}；"
            f"本地/函数工具 {_as_int(counts.get('tool_calls'))}",
            "  图片输入 token 已折入 Input；Codex 当前不能提供独立图片 token。",
            "  Web/File Search、容器、图片生成、外部 MCP 等按次/存储费用未计入。",
            "",
            "准确度",
            "  Credits 为官方 Codex rate card 估算；API USD 是等价估算，不是订阅实际账单。",
            "  Fast/Standard 数值是按线程设置估算；transcript 不含提供商最终 effective tier。",
            f"  价格目录 {report.get('pricing_catalog', {}).get('catalog_id')}；"
            f"范围：{report.get('pricing_catalog', {}).get('scope') or '未声明'}",
        ]
    )
    warnings = list(report.get("warnings") or [])
    warnings += list((task.get("cost") or {}).get("warnings") or [])
    warnings = list(dict.fromkeys(warnings))
    if warnings:
        lines.extend(["", "警告"])
        lines.extend(f"  - {warning}" for warning in warnings)
    return "\n".join(lines) + "\n"


def save_report(report: Dict[str, Any]) -> Tuple[Path, Path]:
    root_id = str(report.get("root_thread_id") or "unknown")
    report_dir = _state_dir() / "reports"
    json_text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    text_value = format_full(report)
    json_path = report_dir / f"{root_id}.json"
    text_path = report_dir / f"{root_id}.txt"
    # Each destination is atomic and always individually valid. If the Stop
    # budget expires between views, a later run refreshes the older view; never
    # defer SIGALRM here because returning a valid hook response is higher
    # priority than cross-file generation consistency.
    _atomic_write(json_path, json_text)
    _atomic_write(text_path, text_value)
    # Historical backfill runs set this process-local flag so generating an
    # older per-session report never moves the live "latest" pointer backwards.
    if os.environ.get("CODEX_TOKEN_USAGE_SKIP_LATEST") != "1":
        _atomic_write(report_dir / "latest.json", json_text)
        _atomic_write(report_dir / "latest.txt", text_value)
    return json_path, text_path


def handle_hook_event(event: Dict[str, Any]) -> Optional[str]:
    """Return a UI-only status message for a root Stop event.

    All exceptions are swallowed here so usage reporting can never block or
    change the original Codex task.
    """
    if not isinstance(event, dict) or event.get("hook_event_name") != "Stop":
        return None
    root_id = event.get("session_id")
    transcript = event.get("transcript_path")
    if not isinstance(root_id, str) or not root_id or not isinstance(transcript, str) or not transcript:
        return None
    try:
        report = build_report(
            root_id=root_id,
            transcript_path=Path(transcript),
            turn_id=event.get("turn_id") if isinstance(event.get("turn_id"), str) else None,
            event=event,
            use_cache=True,
        )
        save_report(report)
        return format_hover(report)
    except Exception as exc:  # Fail open: never steer or block the Codex turn.
        if os.environ.get("CODEX_TOKEN_USAGE_DEBUG") == "1":
            sys.stderr.write(f"TOKEN USAGE HOOK ERROR: {exc}\n")
        return None


def _resolve_cli_target(args: argparse.Namespace) -> Tuple[str, Optional[Path]]:
    codex_dir = _codex_dir()
    if args.transcript:
        path = Path(args.transcript).expanduser().resolve()
        state = parse_transcript(path, use_cache=not args.no_cache)
        thread_id = state.get("thread_id")
        if not isinstance(thread_id, str) or not thread_id:
            raise RuntimeError("transcript has no session id")
        return thread_id, path
    connection = _connect_state_db(codex_dir)
    try:
        row = _thread_row(connection, args.session) if args.session else _latest_user_thread(connection)
    finally:
        connection.close()
    thread_id = row.get("id")
    if not isinstance(thread_id, str) or not thread_id:
        raise RuntimeError("no matching Codex task was found")
    return thread_id, _resolve_transcript(row, thread_id, codex_dir)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Show local Codex token usage without a model call")
    parser.add_argument("--session", help="root Codex thread/session id")
    parser.add_argument("--transcript", help="root rollout JSONL path")
    parser.add_argument("--turn", help="turn id to show as the current turn")
    parser.add_argument("--compact", action="store_true", help="print the compact UI message")
    parser.add_argument("--json", action="store_true", help="print the machine-readable report")
    parser.add_argument("--no-cache", action="store_true", help="reparse complete transcripts")
    args = parser.parse_args(argv)
    try:
        thread_id, path = _resolve_cli_target(args)
        report = build_report(
            root_id=thread_id,
            transcript_path=path,
            turn_id=args.turn,
            use_cache=not args.no_cache,
        )
        save_report(report)
    except Exception as exc:
        sys.stderr.write(f"codex-tokens: {exc}\n")
        return 1
    if args.json:
        sys.stdout.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    elif args.compact:
        sys.stdout.write(format_compact(report) + "\n")
    else:
        sys.stdout.write(format_full(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
