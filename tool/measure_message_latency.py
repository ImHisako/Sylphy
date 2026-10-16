"""Opt-in, two-device UI latency measurements using a single host clock.

Requires two authorized Android devices with test conversations already open.
No device settings are changed; XML snapshots stay in memory. ADB sampling adds
uncertainty, so results are intervals rather than invented precise latencies.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass


class MeasurementError(RuntimeError):
    pass


@dataclass
class Snapshot:
    root: ET.Element
    started: float
    finished: float

    def contains(self, text: str) -> bool:
        return any(text in node.get(key, "") for node in self.root.iter("node")
                   for key in ("text", "content-desc"))


def parse_hierarchy(output: str) -> ET.Element:
    if len(output) > 8 * 1024 * 1024:
        raise MeasurementError("Gerarchia UI troppo grande.")
    begin = output.find("<hierarchy")
    end = output.rfind("</hierarchy>")
    if begin < 0 or end < begin:
        raise MeasurementError("Gerarchia UI assente: sblocca il telefono e apri la chat.")
    try:
        return ET.fromstring(output[begin:end + len("</hierarchy>")])
    except ET.ParseError as error:
        raise MeasurementError("Gerarchia UI non valida.") from error


def center(node: ET.Element) -> tuple[int, int]:
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not match:
        raise MeasurementError("Coordinate UI non valide.")
    left, top, right, bottom = map(int, match.groups())
    if right <= left or bottom <= top:
        raise MeasurementError("Controllo UI non visibile.")
    return (left + right) // 2, (top + bottom) // 2


def only(nodes: list[ET.Element], what: str) -> ET.Element:
    if len(nodes) != 1:
        raise MeasurementError(f"{what}: atteso un solo controllo visibile.")
    return nodes[0]


def validate_chat(snapshot: Snapshot, title: str) -> tuple[ET.Element, ET.Element]:
    nodes = [node for node in snapshot.root.iter("node")
             if node.get("package") == "com.sylphy" and node.get("enabled", "true") == "true"]
    if not any(title == node.get(key, "") for node in nodes for key in ("text", "content-desc")):
        raise MeasurementError("La chat aperta non corrisponde al contatto di test specificato.")
    editor = only([node for node in nodes if node.get("class") == "android.widget.EditText"], "Campo messaggio")
    # Refuse to overwrite a draft. The hint can be exposed as text by Flutter.
    if editor.get("text", "") not in ("", "Scrivi un messaggio privato…"):
        raise MeasurementError("La chat contiene una bozza: svuotala prima della prova.")
    send = only([node for node in nodes if node.get("content-desc") == "Invia messaggio"], "Pulsante invio")
    center(editor)
    center(send)
    return editor, send


class Adb:
    def __init__(self, executable: str):
        self.executable = executable

    def run(self, *args: str) -> str:
        result = subprocess.run([self.executable, *args], capture_output=True,
                                encoding="utf-8", errors="replace", timeout=20, check=False)
        if result.returncode:
            # Do not copy command output or UI content into diagnostics.
            raise MeasurementError("Comando ADB non riuscito.")
        return result.stdout

    def devices(self) -> set[str]:
        return {parts[0] for line in self.run("devices").splitlines()
                if len(parts := line.split()) >= 2 and parts[1] == "device"}

    def snapshot(self, serial: str) -> Snapshot:
        started = time.monotonic()
        # Stream directly to the host: no plaintext UI dump on shared storage.
        output = self.run("-s", serial, "exec-out", "uiautomator", "dump", "/proc/self/fd/1")
        finished = time.monotonic()
        return Snapshot(parse_hierarchy(output), started, finished)

    def tap(self, serial: str, node: ET.Element) -> None:
        x, y = center(node)
        self.run("-s", serial, "shell", "input", "tap", str(x), str(y))

    def type_probe(self, serial: str, text: str) -> None:
        if not re.fullmatch(r"SylphyProbe_[0-9a-f]{24}", text):
            raise MeasurementError("Messaggio di prova non valido.")
        self.run("-s", serial, "shell", "input", "text", text)


def latency_bounds(send_started: float, send_finished: float,
                   last_absent: Snapshot, first_present: Snapshot) -> tuple[float, float]:
    # Snapshot capture occurs somewhere inside the ADB command interval.
    lower = max(0.0, last_absent.started - send_finished) * 1000
    upper = max(0.0, first_present.finished - send_started) * 1000
    return round(lower, 3), round(max(lower, upper), 3)


def measure_sample(adb: Adb, sender: str, receiver: str, sender_title: str,
                   receiver_title: str, timeout: float, poll: float) -> dict:
    probe = "SylphyProbe_" + secrets.token_hex(12)
    sender_snapshot = adb.snapshot(sender)
    editor, _ = validate_chat(sender_snapshot, sender_title)
    absent = adb.snapshot(receiver)
    validate_chat(absent, receiver_title)
    if absent.contains(probe):
        raise MeasurementError("Identificativo di prova già presente.")
    adb.tap(sender, editor)
    adb.type_probe(sender, probe)
    # Keyboard appearance can move the send button: read its current position.
    prepared = adb.snapshot(sender)
    send = only([node for node in prepared.root.iter("node")
                 if node.get("package") == "com.sylphy" and node.get("content-desc") == "Invia messaggio"
                 and node.get("enabled", "true") == "true"], "Pulsante invio")
    if not prepared.contains(sender_title):
        raise MeasurementError("La chat del mittente è cambiata durante la preparazione.")
    started = time.monotonic()
    adb.tap(sender, send)
    finished = time.monotonic()
    deadline = started + timeout
    while time.monotonic() < deadline:
        snapshot = adb.snapshot(receiver)
        validate_chat(snapshot, receiver_title)
        if snapshot.contains(probe):
            low, high = latency_bounds(started, finished, absent, snapshot)
            return {"outcome": "visible", "lower_bound_ms": low, "upper_bound_ms": high,
                    "uncertainty_ms": round(high - low, 3),
                    "last_snapshot_cost_ms": round((snapshot.finished - snapshot.started) * 1000, 3)}
        absent = snapshot
        time.sleep(poll)
    return {"outcome": "timeout", "timeout_seconds": timeout}


def report(samples: list[dict]) -> dict:
    received = [sample for sample in samples if sample["outcome"] == "visible"]
    result = {"format": "sylphy-ui-latency", "version": 1, "scenario": "foreground",
              "clock": "single-host-monotonic", "percentiles_population": "visible_samples_only",
              "attempted": len(samples),
              "visible": len(received), "timed_out": len(samples) - len(received),
              "note": "Intervalli osservati dalla UI; includono incertezza ADB e campionamento. Non sono tempi precisi del solo trasporto.",
              "samples": samples}
    if received:
        for label, quantile in (("p50", .5), ("p95", .95)):
            index = max(0, math.ceil(len(received) * quantile) - 1)
            result[label + "_bounds_ms"] = [sorted(sample[key] for sample in received)[index]
                                           for key in ("lower_bound_ms", "upper_bound_ms")]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default=shutil.which("adb"))
    parser.add_argument("--sender", required=True)
    parser.add_argument("--receiver", required=True)
    parser.add_argument("--sender-chat-title", required=True)
    parser.add_argument("--receiver-chat-title", required=True)
    parser.add_argument("--send-test-messages", action="store_true")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--poll", type=float, default=.25)
    parser.add_argument("--output", type=Path, default=Path("build/physical-message-latency.json"))
    args = parser.parse_args()
    if not args.adb or not args.send_test_messages:
        parser.error("Specifica ADB e --send-test-messages: la prova invia messaggi ai contatti di test indicati.")
    if args.sender == args.receiver or not 1 <= args.samples <= 100 or not 5 <= args.timeout <= 300 or not .1 <= args.poll <= 10:
        parser.error("Servono due dispositivi diversi e parametri di misura entro i limiti.")
    adb = Adb(args.adb)
    try:
        if not {args.sender, args.receiver} <= adb.devices():
            raise MeasurementError("Servono due telefoni collegati e autorizzati. Nessuna misura eseguita.")
        samples = [measure_sample(adb, args.sender, args.receiver, args.sender_chat_title,
                                  args.receiver_chat_title, args.timeout, args.poll)
                   for _ in range(args.samples)]
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report(samples), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Risultati salvati: {args.output}")
        return 0 if all(sample["outcome"] == "visible" for sample in samples) else 2
    except (MeasurementError, subprocess.TimeoutExpired, OSError) as error:
        print(str(error) if isinstance(error, MeasurementError) else "Prova interrotta: errore ADB o di archiviazione.")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
