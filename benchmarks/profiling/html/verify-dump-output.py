"""Compare one fresh bounded extraction with retained parser and CSV evidence."""
from __future__ import annotations

import csv
import copy
import hashlib
import json
import os
import sys
from decimal import Decimal
from pathlib import Path

MARKER = "::RelayHoldProof_415ee562_Editor"
EVENT_CATEGORY_COUNT = 14
MAX_SAFE_INTEGER = 9_007_199_254_740_991
SEMANTIC_KEYS = (
    "frames", "markerDescriptors", "markerExecutions", "networkRecords",
    "unknownEvents", "packetRelationships", "unresolvedLinks", "accounting",
    "availability", "unsupported", "viewerTotals",
)


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"), parse_float=Decimal)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def within(path: Path, directory: Path) -> bool:
    return path == directory or directory in path.parents


def exact_keys(value, keys) -> bool:
    return isinstance(value, dict) and set(value) == set(keys)


def safe_counter(value, keys) -> bool:
    if not exact_keys(value, keys):
        return False
    for field in keys:
        number = value[field]
        if type(number) is not int or number < 0 or number > MAX_SAFE_INTEGER:
            return False
    return True


def viewer_total_matches_frame(total, frame) -> bool:
    if not isinstance(total, dict) or not exact_keys(total.get("totals"), ("rx", "tx")):
        return False
    if not safe_counter(total["totals"]["rx"], ("sum", "count")):
        return False
    if not safe_counter(total["totals"]["tx"], ("sum", "count")):
        return False
    expected = frame.get("viewerNetworkTotals")
    if not exact_keys(expected, ("Rx", "Tx")):
        return False
    for direction, field in (("Rx", "rx"), ("Tx", "tx")):
        expected_bucket = expected[direction]
        if not safe_counter(expected_bucket, ("bytes", "count")):
            return False
        observed = total["totals"][field]
        if observed["sum"] != expected_bucket["bytes"] or observed["count"] != expected_bucket["count"]:
            return False

    categories = total.get("eventStats")
    if not isinstance(categories, list) or len(categories) != EVENT_CATEGORY_COUNT:
        return False
    for category in categories:
        if not exact_keys(category, ("rx", "tx")):
            return False
        if not safe_counter(category["rx"], ("sum", "count")):
            return False
        if not safe_counter(category["tx"], ("sum", "count")):
            return False
    return True


def positive_path_scope(retained_root: Path, historical_path: Path, fresh_path: Path,
                         output: Path, source_dir: Path, anchor_path: Path):
    retained_root, historical_path, fresh_path, output = (
        path.resolve() for path in (retained_root, historical_path, fresh_path, output)
    )
    source_dir, anchor_path = source_dir.resolve(), anchor_path.resolve()
    if not within(historical_path, retained_root) or historical_path == retained_root:
        raise ValueError("historical report must be inside the explicit retained evidence root")
    protected_directories = (retained_root, source_dir, anchor_path.parent)
    for label, candidate in (("fresh extraction", fresh_path), ("verification report", output)):
        if any(within(candidate, directory) for directory in protected_directories):
            raise ValueError(f"{label} must be outside retained evidence, verifier source, and anchor directories")
    if fresh_path in (historical_path, output) or output == historical_path:
        raise ValueError("fresh extraction and verification report must be distinct files")
    return retained_root, historical_path, fresh_path, output


def read_csv(path: Path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.reader(stream))
    descriptors, frames, executions = [], [], []
    frame_index, thread_name = None, None
    for index, row in enumerate(rows):
        if row and row[0] == MARKER:
            descriptors.append(row)
        if row and row[0] == "Frame" and len(row) > 1 and row[1] == "Frame Begin Time CPU (ms)":
            following = rows[index + 1]
            frame_index = int(following[0])
            frames.append({
                "index": frame_index,
                "startMilliseconds": Decimal(following[1]),
                "endMilliseconds": Decimal(following[2]),
                "gpuStartMilliseconds": Decimal(following[3]),
                "gpuEndMilliseconds": Decimal(following[4]),
            })
        elif row and row[0] == "Thread Name:":
            thread_name = row[1]
        elif len(row) >= 4 and row[1] == MARKER:
            executions.append({
                "frame": frame_index, "threadName": thread_name,
                "startMilliseconds": Decimal(row[2]),
                "endMilliseconds": Decimal(row[3]), "csvRow": index + 1,
            })
    return descriptors, frames, executions


def semantic_diff(a, b):
    differences = []
    for key in SEMANTIC_KEYS:
        if a.get(key) == b.get(key):
            continue
        if key == "availability" and isinstance(a.get(key), dict) and isinstance(b.get(key), dict):
            differences.extend(
                f"availability.{field}"
                for field in sorted(set(a[key]) | set(b[key]))
                if a[key].get(field) != b[key].get(field)
            )
        else:
            differences.append(key)
    return differences


def viewer_totals_match_frames(extracted):
    totals = extracted.get("viewerTotals")
    frames = extracted.get("frames")
    if extracted.get("availability", {}).get("viewerNetworkTotalsAvailable") is not True:
        return False
    if (not isinstance(totals, list) or not isinstance(frames, list) or not frames
            or len(totals) != len(frames)):
        return False
    for total, frame in zip(totals, frames):
        if not viewer_total_matches_frame(total, frame):
            return False
    return True


def historical_viewer_totals_are_sparse(extracted):
    totals = extracted.get("viewerTotals")
    frames = extracted.get("frames")
    if not isinstance(totals, list) or not isinstance(frames, list) or not frames or len(totals) != len(frames):
        return False
    for total in totals:
        if not isinstance(total, dict) or total.get("totals", object()) is not None:
            return False
        categories = total.get("eventStats")
        if not isinstance(categories, list) or len(categories) != EVENT_CATEGORY_COUNT:
            return False
        for category in categories:
            if not exact_keys(category, ("rx", "tx")):
                return False
            if not exact_keys(category["rx"], ()) or not exact_keys(category["tx"], ()):
                return False
    return True


def hold_zero_record_viewer_totals_allowed(fresh, historical):
    if (fresh["networkRecords"]
            or historical["accounting"]["qualifiedObservedTotals"] is not None
            or fresh["accounting"]["qualifiedObservedTotals"] is not None
            or not historical_viewer_totals_are_sparse(historical)
            or not viewer_totals_match_frames(fresh)):
        return False
    for frame in fresh["frames"]:
        totals = frame["viewerNetworkTotals"]
        if any(totals[direction][field] != 0 for direction in ("Rx", "Tx")
               for field in ("bytes", "count")):
            return False
    for total in fresh["viewerTotals"]:
        for category in total["eventStats"]:
            if any(category[direction][field] != 0 for direction in ("rx", "tx")
                   for field in ("sum", "count")):
                return False
    return True


def structural_regression_checks():
    frame = {"viewerNetworkTotals": {
        "Rx": {"bytes": 7, "count": 2}, "Tx": {"bytes": 3, "count": 1},
    }}
    bucket = lambda: {"sum": 0, "count": 0}
    viewer = {"totals": {"rx": {"sum": 7, "count": 2}, "tx": {"sum": 3, "count": 1}},
              "eventStats": [{"rx": bucket(), "tx": bucket()} for _ in range(EVENT_CATEGORY_COUNT)]}
    if not viewer_total_matches_frame(viewer, frame):
        raise AssertionError("valid pinned viewer totals were rejected")
    missing_category = copy.deepcopy(viewer)
    missing_category["eventStats"].pop()
    if viewer_total_matches_frame(missing_category, frame):
        raise AssertionError("viewer totals with a dropped category were accepted")
    missing_field = copy.deepcopy(viewer)
    del missing_field["eventStats"][0]["rx"]["count"]
    if viewer_total_matches_frame(missing_field, frame):
        raise AssertionError("viewer totals with a dropped field were accepted")
    boolean_field = copy.deepcopy(viewer)
    boolean_field["eventStats"][0]["rx"]["count"] = True
    if viewer_total_matches_frame(boolean_field, frame):
        raise AssertionError("boolean viewer counter was accepted as an integer")

    zero_frame = {"viewerNetworkTotals": {
        "Rx": {"bytes": 0, "count": 0}, "Tx": {"bytes": 0, "count": 0},
    }}
    zero_total = {"totals": {"rx": {"sum": 0, "count": 0}, "tx": {"sum": 0, "count": 0}},
                  "eventStats": [{"rx": bucket(), "tx": bucket()} for _ in range(EVENT_CATEGORY_COUNT)]}
    zero_fresh = {
        "networkRecords": [], "frames": [zero_frame], "viewerTotals": [zero_total],
        "availability": {"viewerNetworkTotalsAvailable": True},
        "accounting": {"qualifiedObservedTotals": None},
    }
    zero_historical = {
        "frames": [zero_frame],
        "viewerTotals": [{"totals": None, "eventStats": [
            {"rx": {}, "tx": {}} for _ in range(EVENT_CATEGORY_COUNT)
        ]}],
        "accounting": {"qualifiedObservedTotals": None},
    }
    if not hold_zero_record_viewer_totals_allowed(zero_fresh, zero_historical):
        raise AssertionError("fully zero hold viewer totals were rejected")
    nonzero_category_sum = copy.deepcopy(zero_fresh)
    nonzero_category_sum["viewerTotals"][0]["eventStats"][0]["rx"]["sum"] = 1
    nonzero_category_count = copy.deepcopy(zero_fresh)
    nonzero_category_count["viewerTotals"][0]["eventStats"][0]["tx"]["count"] = 1
    nonzero_frame_totals = copy.deepcopy(zero_fresh)
    nonzero_frame_totals["frames"][0]["viewerNetworkTotals"]["Rx"] = {"bytes": 2, "count": 1}
    nonzero_frame_totals["viewerTotals"][0]["totals"]["rx"] = {"sum": 2, "count": 1}
    if (hold_zero_record_viewer_totals_allowed(nonzero_category_sum, zero_historical)
            or hold_zero_record_viewer_totals_allowed(nonzero_category_count, zero_historical)
            or hold_zero_record_viewer_totals_allowed(nonzero_frame_totals, zero_historical)):
        raise AssertionError("zero-record hold exception accepted nonzero category or frame totals")

    root = Path("E:/relay-retained-root")
    history = root / "post-fix" / "historical.json"
    sibling_fresh = root / "sibling" / "fresh.json"
    sibling_report = root / "sibling" / "verification.json"
    try:
        positive_path_scope(root, history, sibling_fresh, sibling_report,
                            Path("E:/relay/benchmarks/profiling/html"), Path("E:/relay-assets/anchor.html"))
    except ValueError:
        pass
    else:
        raise AssertionError("fresh sibling evidence output was not rejected")
    return ["dropped-category-rejected", "dropped-counter-field-rejected",
            "boolean-counter-rejected", "zero-hold-totals-validated", "sibling-evidence-output-rejected"]


def compare_positive(retained_root: Path, historical_path: Path, fresh_path: Path, output: Path) -> int:
    anchor = os.environ.get("RELAY_PROFILE_ASSETS")
    if not anchor or not Path(anchor).is_absolute():
        raise SystemExit("RELAY_PROFILE_ASSETS must be an absolute anchor path for positive parity checks")
    try:
        retained_root, historical_path, fresh_path, output = positive_path_scope(
            retained_root, historical_path, fresh_path, output, Path(__file__).resolve().parent, Path(anchor)
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    if not historical_path.is_file() or not fresh_path.is_file():
        raise SystemExit("historical positive report and fresh extraction must exist")
    if output.exists():
        raise SystemExit("verification report already exists")
    if not output.parent.is_dir():
        raise SystemExit("verification report parent directory must already exist")
    regression_checks = structural_regression_checks()
    historical, fresh = read_json(historical_path), read_json(fresh_path)
    differences = semantic_diff(fresh, historical)
    checks = {
        "normalizedSemanticFieldsMatchExactly": not differences,
        "inputHtmlIdentityMatches": fresh["provenance"]["htmlSha256"] == historical["provenance"]["htmlSha256"],
        "positiveNetworkRecordsPresent": len(fresh["networkRecords"]) > 0,
        "recordAndParentRelationshipCountsMatch": len(fresh["networkRecords"]) == len(historical["networkRecords"])
            and len(fresh["packetRelationships"]) == len(historical["packetRelationships"])
            and len(fresh["unresolvedLinks"]) == len(historical["unresolvedLinks"]),
        "accountingMatchesExactly": fresh["accounting"] == historical["accounting"],
        "viewerTotalsMatchNormalizedFrames": viewer_totals_match_frames(fresh),
        "workloadAttributionRemainsUnset": fresh["qualification"]["workloadAttributed"] is False
            and fresh["accounting"]["workloadAttributed"] is False,
    }
    report = {
        "format": "relay-positive-dump-output-verification-v1",
        "passed": all(checks.values()),
        "checks": checks,
        "structuralRegressionChecks": regression_checks,
        "semanticFieldsComparedExactly": list(SEMANTIC_KEYS),
        "semanticDifferences": differences,
        "freshExtraction": {
            "path": str(fresh_path), "sha256": digest(fresh_path),
            "inputHtmlSha256": fresh["provenance"]["htmlSha256"],
            "recordCount": len(fresh["networkRecords"]),
            "packetRelationshipCount": len(fresh["packetRelationships"]),
            "unresolvedLinkCount": len(fresh["unresolvedLinks"]),
        },
        "historicalReport": {"path": str(historical_path), "sha256": digest(historical_path)},
        "retainedEvidenceRoot": str(retained_root),
        "limits": [
            "This retained positive export validates decoder parity for its records and viewer accounting only.",
            "It does not establish workload attribution, physical-wire bytes, a local interval rate, or packet history outside the saved export.",
        ],
    }
    with output.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(report, indent=2, default=str) + "\n")
    print(json.dumps({"passed": report["passed"], "report": str(output), "checks": checks,
                      "semanticDifferences": differences}))
    return 0 if report["passed"] else 1


def main(history: Path, fresh_path: Path, output: Path) -> int:
    history, fresh_path, output = history.resolve(), fresh_path.resolve(), output.resolve()
    if not history.is_dir() or not fresh_path.is_file():
        raise SystemExit("retained analysis directory and fresh extraction file must exist")
    if history in fresh_path.parents:
        raise SystemExit("fresh extraction must be outside retained evidence")
    if output.exists():
        raise SystemExit("verification report already exists")
    if output == history or history in output.parents or fresh_path == output:
        raise SystemExit("report must be new and outside retained evidence and the fresh extraction")
    if not output.parent.is_dir():
        raise SystemExit("verification report parent directory must already exist")

    regression_checks = structural_regression_checks()
    fresh = read_json(fresh_path)
    historical = read_json(history / "hold-before.network.json")
    old_after = read_json(history / "hold-after.network.json")
    old_repeat = read_json(history / "hold-before.repeat.network.json")
    summary = read_json(history / "hold-before_summary.json")
    descriptors, frames, executions = read_csv(history / "hold-before.csv")
    editor = read_json(history / "editor-high.network.json")
    pinned_oracle = read_json(history / "pinned-viewer-oracle-verification.json")

    checks = {
        "freshNormalizedSemanticsMatchHistoricalParserExceptDocumentedFields": True,
        "freshFrameCountMatchesSummary": len(fresh["frames"]) == summary["num_frames"] == 32,
        "freshFrameCountMatchesCsvSections": len(fresh["frames"]) == len(frames),
        "freshFrameTimesMatchCsvExactly": all(
            all(record[key] == frame[key] for key in frame)
            for record, frame in zip(fresh["frames"], frames)
        ),
        "freshMarkerDescriptorMatchesCsv": len(fresh["markerDescriptors"]) == len(descriptors) == 1,
        "freshMarkerExecutionsMatchCsv": len(fresh["markerExecutions"]) == len(executions) == 32,
        "freshMarkersHaveCapturedExit": all(record["closed"] for record in fresh["markerExecutions"]),
        "freshMarkerTimesMatchCsvExactly": [
            (record["frame"], record["startMilliseconds"], record["endMilliseconds"])
            for record in fresh["markerExecutions"]
        ] == [(record["frame"], record["startMilliseconds"], record["endMilliseconds"]) for record in executions],
        "freshEmptyNetworkDoesNotQualifyZeroTraffic": len(fresh["networkRecords"]) == 0
            and fresh["accounting"]["qualifiedObservedTotals"] is None
            and not fresh["availability"]["networkRecordsPresent"],
        "freshViewerTotalsMatchFrameAccounting": viewer_totals_match_frames(fresh),
        "retainedHoldPairSemanticFieldsMatch": not semantic_diff(historical, old_after),
        "retainedSameInputRepeatMatches": not semantic_diff(historical, old_repeat),
        "retainedEditorEmptyNetworkIsExplicit": len(editor["frames"]) == 32 and len(editor["networkRecords"]) == 0
            and editor["accounting"]["qualifiedObservedTotals"] is None,
        "pinnedViewerSyntheticOraclePasses": pinned_oracle["passed"]
            and pinned_oracle["viewerSha256"] == fresh["provenance"]["viewerSha256"],
    }
    exact_differences = semantic_diff(fresh, historical)
    allowed_differences = []
    documented_difference_details = []
    if ("availability.viewerNetworkTotalsAvailable" in exact_differences
            and "viewerNetworkTotalsAvailable" not in historical["availability"]
            and fresh["availability"].get("viewerNetworkTotalsAvailable") is True):
        allowed_differences.append("availability.viewerNetworkTotalsAvailable")
        documented_difference_details.append({
            "field": "availability.viewerNetworkTotalsAvailable",
            "historical": "field absent",
            "fresh": True,
            "reason": "the promoted report explicitly states that viewer totals were decoded",
        })
    if "viewerTotals" in exact_differences and hold_zero_record_viewer_totals_allowed(fresh, historical):
        allowed_differences.append("viewerTotals")
        documented_difference_details.append({
            "field": "viewerTotals",
            "historical": "totals null and category buckets empty",
            "fresh": "explicit zero values matching every normalized frame",
            "reason": "only accepted for this zero-record, unqualified hold export; accounting remains exactly equal",
        })
    unexpected_differences = [field for field in exact_differences if field not in allowed_differences]
    checks["freshNormalizedSemanticsMatchHistoricalParserExceptDocumentedFields"] = not unexpected_differences
    report = {
        "format": "relay-dump-output-verification-v1",
        "passed": all(checks.values()),
        "checks": checks,
        "structuralRegressionChecks": regression_checks,
        "semanticFieldsCompared": list(SEMANTIC_KEYS),
        "exactDifferencesFromHistorical": exact_differences,
        "documentedHistoricalDifferences": documented_difference_details,
        "unexpectedDifferencesFromHistorical": unexpected_differences,
        "freshExtraction": {
            "path": str(fresh_path), "sha256": digest(fresh_path),
            "inputHtmlSha256": fresh["provenance"]["htmlSha256"],
            "parserSha256": fresh["provenance"]["parserSha256"],
        },
        "historicalEvidence": {
            name: digest(history / name) for name in (
                "hold-before.network.json", "hold-before_summary.json", "hold-before.csv",
                "hold-after.network.json", "hold-before.repeat.network.json",
                "editor-high.network.json", "pinned-viewer-oracle-verification.json",
            )
        },
        "limits": [
            "The retained HTML exports contain no decoded network records; this does not prove zero traffic.",
            "No workload attribution, physical-wire bytes, local interval rate, or absolute frame identity is qualified.",
            "The synthetic viewer oracle does not exercise the vendor binary decoder on a positive real network dump.",
        ],
    }
    with output.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(report, indent=2, default=str) + "\n")
    print(json.dumps({"passed": report["passed"], "report": str(output), "checks": checks}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "--positive":
        raise SystemExit(compare_positive(Path(sys.argv[2]), Path(sys.argv[3]),
                                          Path(sys.argv[4]), Path(sys.argv[5])))
    if len(sys.argv) == 4:
        raise SystemExit(main(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])))
    raise SystemExit(
        "usage: verify-dump-output.py RETAINED_ANALYSIS_DIR FRESH_HOLD_EXTRACTION.json NEW_REPORT.json\n"
        "   or: verify-dump-output.py --positive RETAINED_EVIDENCE_ROOT RETAINED_POSITIVE_REPORT.json "
        "FRESH_EXTRACTION.json NEW_REPORT.json"
    )
