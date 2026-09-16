#!/usr/bin/env python3
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def require(text: str, needle: str, name: str, findings: list):
    count = text.count(needle)
    findings.append({"check": name, "expected": 1, "actual": count, "pass": count == 1})
    if count != 1:
        raise AssertionError(f"{name}: expected exactly one occurrence, got {count}: {needle!r}")


def require_at_least(text: str, needle: str, minimum: int, name: str, findings: list):
    count = text.count(needle)
    findings.append({"check": name, "minimum": minimum, "actual": count, "pass": count >= minimum})
    if count < minimum:
        raise AssertionError(f"{name}: expected at least {minimum} occurrences, got {count}: {needle!r}")


def forbid(text: str, needle: str, name: str, findings: list):
    count = text.count(needle)
    findings.append({"check": name, "expected": 0, "actual": count, "pass": count == 0})
    if count != 0:
        raise AssertionError(f"{name}: forbidden occurrence count={count}: {needle!r}")


def verify(root: Path):
    findings = []
    rels = {
        "scheduler": Path("src/video_core/renderer_vulkan/vk_scheduler.cpp"),
        "gpu": Path("src/video_core/renderer_vulkan/bb_gpu_trace.cpp"),
        "recorder_main": Path("tools/bb_blackbox/recorder_main.cpp"),
        "decoder": Path("tools/bb_blackbox/decode.py"),
        "driver": Path("src/core/libraries/videoout/driver.cpp"),
        "presenter": Path("src/video_core/renderer_vulkan/vk_presenter.cpp"),
    }
    texts = {}
    hashes = {}
    for key, rel in rels.items():
        path = root / rel
        if not path.is_file():
            raise AssertionError(f"missing required file: {rel}")
        texts[key] = path.read_text(encoding="utf-8")
        hashes[str(rel).replace('\\', '/')] = sha256(path)

    scheduler = texts["scheduler"]
    require(scheduler,
            "if (Common::Blackbox::Recorder::Instance().Enabled()) {\n        bb_gpu_trace = std::make_unique<BlackboxGpuTrace>(instance);\n    }",
            "control_query_pool_gate", findings)
    require(scheduler,
            "(static_cast<u64>(bb_gpu_trace->SchedulerId()) << 32) |\n                                    (local_submit_id & 0xFFFFFFFFULL)",
            "global_submit_identity_composite", findings)
    require(scheduler,
            "master_semaphore.Wait(tick);\n    if (bb_gpu_trace) {\n        bb_gpu_trace->Poll(master_semaphore.KnownGpuTick());\n    }",
            "poll_after_existing_wait", findings)

    gpu = texts["gpu"]
    require(gpu, "Poll(std::numeric_limits<std::uint64_t>::max());",
            "shutdown_nonblocking_final_poll", findings)
    require(gpu, "const std::uint32_t scan_count = pending_count_;",
            "bounded_pending_scan", findings)
    require_at_least(gpu, "PushPending(slot_index);\n            continue;", 2,
                     "pending_query_requeue", findings)
    forbid(gpu, "vk::QueryResultFlagBits::eWait", "no_query_wait_bit", findings)
    forbid(gpu, ".waitIdle(", "no_wait_idle", findings)

    recorder_main = texts["recorder_main"]
    require(recorder_main, "bool producer_quiesced = producer_exited;",
            "producer_quiescence_gate", findings)
    require(recorder_main,
            "for (;;) {\n                const std::size_t tail = consumer.Drain(buffer);\n                if (tail == 0) {\n                    break;\n                }",
            "drain_until_empty", findings)
    forbid(recorder_main, "for (int pass = 0; pass < 2; ++pass)",
           "no_fixed_two_pass_tail_drain", findings)

    driver = texts["driver"]
    require(driver, "const bool bb_is_blank = index == -1;",
            "blank_frame_explicit", findings)
    require(driver, "const u32 bb_frame_hint = bb_is_blank ? 0 : bb_rec.NextGuestFrame();",
            "blank_does_not_create_guest_frame", findings)
    forbid(driver, "EventId::FrameDisplay", "no_unproven_physical_display_label", findings)

    presenter = texts["presenter"]
    require(presenter, "bb_present_ok = swapchain.Present();", "present_result_observed", findings)
    require(presenter, "Common::Blackbox::EventFlags::Success", "present_success_flag", findings)
    require(presenter, "Common::Blackbox::EventId::FramePresent", "present_result_event", findings)
    if presenter.index("bb_present_ok = swapchain.Present();") > presenter.index("Common::Blackbox::EventId::FramePresent"):
        raise AssertionError("FramePresent must be emitted only after swapchain.Present() result is known")
    findings.append({"check": "present_event_after_result", "pass": True})

    decoder = texts["decoder"]
    require(decoder, '"submit_identity_collision_count": 0',
            "decoder_collision_accounting", findings)
    require(decoder, 's["gpu_region_duration_ms_sum"] =',
            "decoder_additive_gpu_region_label", findings)
    require(decoder, 's["gpu_command_buffer_envelope_ms_total"] =',
            "decoder_envelope_total", findings)
    forbid(decoder, 's["gpu_duration_ms_total"] =',
           "no_misleading_gpu_total_assignment", findings)
    require(decoder, 'assert "gpu_duration_ms_total" not in nested_gpu_summary',
            "nested_gpu_double_count_fixture", findings)

    proc = subprocess.run([sys.executable, str(root / rels["decoder"]), "--self-test"],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    findings.append({"check": "decoder_self_test", "pass": proc.returncode == 0,
                     "exit_code": proc.returncode, "output": proc.stdout[-4000:]})
    if proc.returncode != 0:
        raise AssertionError(f"decoder self-test failed: {proc.returncode}\n{proc.stdout}")

    combined = "\n".join(texts.values())
    for token in ("vk::QueryResultFlagBits::eWait", ".waitIdle("):
        if token in combined:
            raise AssertionError(f"forbidden telemetry synchronization token present: {token}")

    return findings, hashes


def self_test():
    assert hashlib.sha256(b"abc").hexdigest() == \
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    return {"pass": True, "helper_sha256": True}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root")
    ap.add_argument("--output")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        print(json.dumps(self_test(), indent=2, sort_keys=True))
        return 0
    if not args.root or not args.output:
        ap.error("--root and --output are required unless --self-test is used")

    root = Path(args.root).resolve()
    out = Path(args.output).resolve()
    result = {"pass": False, "root": str(root), "checks": [], "file_sha256": {}}
    try:
        checks, hashes = verify(root)
        result.update({"pass": True, "checks": checks, "file_sha256": hashes})
    except Exception as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
