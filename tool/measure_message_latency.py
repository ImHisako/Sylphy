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


@dataclass
class NotificationSnapshot:
    signatures: frozenset[str]
    started: float
    finished: float


def notification_signatures(output: str) -> frozenset[str]:
    """Inspect active Sylphy message notification metadata only, in memory."""
    if len(output) > 8 * 1024 * 1024 or "Notification List:" not in output:
        raise MeasurementError("Elenco notifiche attive non disponibile su questo dispositivo.")
    active = output.split("Notification List:", 1)[1]
    for marker in ("Enqueued Notification", "Snoozed", "Historical", "Notification listeners"):
        active = active.split(marker, 1)[0]
    signatures = set()
    for block in re.split(r"(?m)(?=^[ \t]*NotificationRecord\()", active):
        header = block.splitlines()[0] if block.splitlines() else ""
        if not re.search(r"\bpkg=com\.sylphy\b", header) or not re.search(r"\bid=4105\b", header):
            continue
        if "sylphy_messages" not in block:
            continue
        times = re.findall(r"\b(?:postTime|mUpdateTimeMs|mCreationTimeMs)\s*[=:]\s*([^\s,}]+)", block)
        if not times:
            raise MeasurementError("Il dispositivo non espone i tempi delle notifiche: misura non disponibile.")
        # Header/tag and times never leave this in-memory comparison set.
        key = re.search(r"\bkey=([^\s)]+)", header)
        if not key:
            raise MeasurementError("Il dispositivo non espone la chiave delle notifiche: misura non disponibile.")
        signatures.add(key[1] + "|" + "|".join(times))
    return frozenset(signatures)


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

    def notifications(self, serial: str) -> NotificationSnapshot:
        started = time.monotonic()
        signatures = notification_signatures(self.run("-s", serial, "shell", "dumpsys", "notification"))
        return NotificationSnapshot(signatures, started, time.monotonic())

    def interactive(self, serial: str) -> bool:
        output = self.run("-s", serial, "shell", "dumpsys", "power")
        match = re.search(r"mWakefulness=(Awake|Asleep|Dozing|Dreaming)\b", output)
        if not match:
            raise MeasurementError("Stato dello schermo non disponibile: nessuna modifica eseguita.")
        return match[1] in {"Awake", "Dreaming"}

    def screen(self, serial: str, awake: bool) -> None:
        self.run("-s", serial, "shell", "input", "keyevent", "224" if awake else "223")

    def wifi_enabled(self, serial: str) -> bool:
        output = self.run("-s", serial, "shell", "cmd", "wifi", "status").lower()
        if "wifi is enabled" in output:
            return True
        if "wifi is disabled" in output:
            return False
        raise MeasurementError("Stato Wi-Fi non disponibile: nessuna modifica eseguita.")

    def wifi(self, serial: str, enabled: bool) -> None:
        self.run("-s", serial, "shell", "svc", "wifi", "enable" if enabled else "disable")

    def mobile_data_ready(self, serial: str) -> bool:
        enabled = self.run("-s", serial, "shell", "settings", "get", "global", "mobile_data").strip() == "1"
        sim = self.run("-s", serial, "shell", "getprop", "gsm.sim.state")
        return enabled and any(state in sim for state in ("READY", "LOADED"))

    def app_version(self, serial: str) -> dict:
        output = self.run("-s", serial, "shell", "dumpsys", "package", "com.sylphy")
        version = re.search(r"\bversionName=(\d+\.\d+\.\d+)\b", output)
        build = re.search(r"\bversionCode=(\d+)\b", output)
        return {"version": version[1] if version else None, "build": int(build[1]) if build else None}


def latency_bounds(send_started: float, send_finished: float,
                   last_absent: Snapshot, first_present: Snapshot) -> tuple[float, float]:
    # Snapshot capture occurs somewhere inside the ADB command interval.
    lower = max(0.0, last_absent.started - send_finished) * 1000
    upper = max(0.0, first_present.finished - send_started) * 1000
    return round(lower, 3), round(max(lower, upper), 3)


def measure_sample(adb: Adb, sender: str, receiver: str, sender_title: str,
                   receiver_title: str, timeout: float, poll: float,
                   scenario: str = "foreground", allow_device_state_changes: bool = False,
                   confirm_upload_in_progress: bool = False) -> dict:
    if scenario not in {"foreground", "during-upload", "screen-off", "network-change"}:
        raise MeasurementError("Scenario non valido.")
    if scenario in {"screen-off", "network-change"} and not allow_device_state_changes:
        raise MeasurementError("Questo scenario richiede --allow-device-state-changes.")
    if scenario == "network-change" and (not adb.wifi_enabled(receiver) or not adb.mobile_data_ready(receiver)):
        raise MeasurementError("Il cambio rete richiede Wi-Fi attivo, SIM pronta e dati mobili già abilitati.")
    probe = "SylphyProbe_" + secrets.token_hex(12)
    sender_snapshot = adb.snapshot(sender)
    editor, _ = validate_chat(sender_snapshot, sender_title)
    if scenario == "during-upload" and not confirm_upload_in_progress and not sender_snapshot.contains("Invio allegato in corso"):
        raise MeasurementError("Avvia un upload nella chat del mittente prima della prova.")
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
    if scenario == "during-upload" and not confirm_upload_in_progress and not prepared.contains("Invio allegato in corso"):
        raise MeasurementError("Avvia un upload sufficientemente lungo nella chat del mittente prima della prova.")
    if scenario in {"screen-off", "network-change"}:
        if not allow_device_state_changes:
            raise MeasurementError("Questo scenario richiede --allow-device-state-changes.")
        return measure_transition(adb, sender, receiver, send, absent, timeout, poll, probe, scenario)
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


def measure_transition(adb: Adb, sender: str, receiver: str, send: ET.Element,
                       absent: Snapshot, timeout: float, poll: float, probe: str, scenario: str) -> dict:
    screen = scenario == "screen-off"
    if screen:
        if not adb.interactive(receiver):
            raise MeasurementError("Inizia con lo schermo del destinatario acceso e la chat di test aperta.")
    elif not adb.wifi_enabled(receiver) or not adb.mobile_data_ready(receiver):
        raise MeasurementError("Il cambio rete richiede Wi-Fi attivo, SIM pronta e dati mobili già abilitati.")
    # Register restoration before the mutation: even an ADB timeout can follow
    # an operation that the device already executed. Never unlock the device.
    try:
        if screen:
            adb.screen(receiver, False)
            if adb.interactive(receiver):
                raise MeasurementError("Lo schermo del destinatario non si è spento.")
            previous = adb.notifications(receiver)
        else:
            adb.wifi(receiver, False)
            previous = absent
        started = time.monotonic()
        adb.tap(sender, send)
        finished = time.monotonic()
        deadline = started + timeout
        while time.monotonic() < deadline:
            if screen:
                observed = adb.notifications(receiver)
                present = bool(observed.signatures - previous.signatures)
            else:
                observed = adb.snapshot(receiver)
                present = observed.contains(probe)
            if present:
                low, high = latency_bounds(started, finished, previous, observed)
                return {"outcome": "notification_changed" if screen else "visible",
                        "lower_bound_ms": low, "upper_bound_ms": high,
                        "uncertainty_ms": round(high - low, 3),
                        "last_snapshot_cost_ms": round((observed.finished - observed.started) * 1000, 3)}
            previous = observed
            time.sleep(poll)
        return {"outcome": "timeout", "timeout_seconds": timeout}
    finally:
        if screen:
            adb.screen(receiver, True)
        else:
            adb.wifi(receiver, True)


def report(samples: list[dict], scenario: str = "foreground") -> dict:
    outcomes = {"notification_changed"} if scenario == "screen-off" else {"visible"}
    received = [sample for sample in samples if sample["outcome"] in outcomes]
    result = {"format": "sylphy-ui-latency", "version": 2, "scenario": scenario,
              "clock": "single-host-monotonic", "percentiles_population": "visible_samples_only",
              "attempted": len(samples),
              "visible": sum(sample["outcome"] == "visible" for sample in samples),
              "notifications_observed": sum(sample["outcome"] == "notification_changed" for sample in samples),
              "timed_out": sum(sample["outcome"] == "timeout" for sample in samples),
              "note": "Intervalli osservati dalla UI; includono incertezza ADB e campionamento. Non sono tempi precisi del solo trasporto.",
              "samples": samples}
    if scenario == "screen-off":
        result["percentiles_population"] = "notification_changes_only"
        result["note"] = "Variazioni delle notifiche Sylphy, con incertezza ADB. Non misurano la visualizzazione né identificano il singolo messaggio: usare account di test isolati."
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
    parser.add_argument("--scenario", choices=["foreground", "during-upload", "screen-off", "network-change"], default="foreground")
    parser.add_argument("--allow-device-state-changes", action="store_true",
                        help="Consente spegnimento/riaccensione schermo o temporaneo passaggio Wi-Fi → dati mobili sul destinatario.")
    parser.add_argument("--label", choices=["before", "after"], default="after")
    parser.add_argument("--confirm-upload-in-progress", action="store_true",
                        help="Dichiara manualmente un upload in corso, anche sulle build precedenti senza indicatore UI. Il report segnala che la condizione non è verificata automaticamente.")
    parser.add_argument("--pause-between-samples", action="store_true",
                        help="Attende Invio tra campioni: sblocca la chat o riavvia l'upload prima di continuare.")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--poll", type=float, default=.25)
    parser.add_argument("--output", type=Path, default=Path("build/physical-message-latency.json"))
    args = parser.parse_args()
    if not args.adb or not args.send_test_messages:
        parser.error("Specifica ADB e --send-test-messages: la prova invia messaggi ai contatti di test indicati.")
    if args.sender == args.receiver or not 1 <= args.samples <= 100 or not 5 <= args.timeout <= 300 or not .1 <= args.poll <= 10:
        parser.error("Servono due dispositivi diversi e parametri di misura entro i limiti.")
    if args.scenario in {"screen-off", "network-change"} and not args.allow_device_state_changes:
        parser.error("Lo scenario scelto modifica temporaneamente il destinatario: aggiungi --allow-device-state-changes.")
    if args.scenario == "screen-off" and args.samples > 1 and not args.pause_between_samples:
        parser.error("Con schermo spento usa --samples 1 oppure --pause-between-samples per risbloccare manualmente il dispositivo.")
    adb = Adb(args.adb)
    samples = []
    versions = None
    try:
        if not {args.sender, args.receiver} <= adb.devices():
            raise MeasurementError("Servono due telefoni collegati e autorizzati. Nessuna misura eseguita.")
        versions = {"sender": adb.app_version(args.sender), "receiver": adb.app_version(args.receiver)}
        for index in range(args.samples):
            if index and args.pause_between_samples:
                input("Ripristina le chat di test e le condizioni dello scenario, poi premi Invio. ")
            samples.append(measure_sample(adb, args.sender, args.receiver, args.sender_chat_title,
                                          args.receiver_chat_title, args.timeout, args.poll,
                                          args.scenario, args.allow_device_state_changes,
                                          args.confirm_upload_in_progress))
        result = report(samples, args.scenario)
        result.update({"label": args.label, "builds": versions})
        if args.scenario == "during-upload":
            result['upload_condition'] = 'user_confirmed' if args.confirm_upload_in_progress else 'ui_verified'
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Risultati salvati: {args.output}")
        return 0 if all(sample["outcome"] in {"visible", "notification_changed"} for sample in samples) else 2
    except (MeasurementError, subprocess.TimeoutExpired, OSError, EOFError) as error:
        if versions is not None:
            partial = report(samples, args.scenario)
            partial.update({"label": args.label, "builds": versions, "incomplete": True})
            if args.scenario == "during-upload":
                partial['upload_condition'] = 'user_confirmed' if args.confirm_upload_in_progress else 'ui_verified'
            try:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(partial, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            except OSError:
                pass
        print(str(error) if isinstance(error, MeasurementError) else "Prova interrotta: errore ADB o di archiviazione.")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
