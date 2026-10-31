"""Compare matching two-device reports without turning sampling bounds into exact gains."""
import argparse
import json
from pathlib import Path


def compare(before: dict, after: dict) -> dict:
    if before.get('incomplete') or after.get('incomplete'):
        raise ValueError("Completa entrambi i gruppi di campioni prima del confronto.")
    for name in ("format", "scenario", "clock", "percentiles_population"):
        if before.get(name) != after.get(name) or before.get(name) is None:
            raise ValueError("I report devono usare lo stesso scenario, orologio e tipo di osservazione.")
    if before["format"] != "sylphy-ui-latency":
        raise ValueError("Servono report dello strumento tra due dispositivi.")
    if before['scenario'] == 'during-upload' and before.get('upload_condition') != after.get('upload_condition'):
        raise ValueError("Confronta upload verificati nello stesso modo: indicatore UI o conferma manuale su entrambe le build.")
    result = {"scenario": before["scenario"], "before_attempted": before["attempted"],
              "after_attempted": after["attempted"], "before_timeouts": before["timed_out"],
              "after_timeouts": after["timed_out"],
              "note": "Delta = dopo − prima; negativo significa meno attesa. Intervalli sovrapposti non dimostrano un miglioramento. Conservare stessi dispositivi, reti e carico."}
    for percentile in ("p50", "p95"):
        left, right = before.get(percentile + "_bounds_ms"), after.get(percentile + "_bounds_ms")
        if left is None or right is None:
            result[percentile + "_delta_bounds_ms"] = None
            continue
        if not all(isinstance(values, list) and len(values) == 2 and
                   all(isinstance(v, (int, float)) and 0 <= v < float('inf') for v in values) and values[0] <= values[1]
                   for values in (left, right)):
            raise ValueError("Intervalli di misura non validi.")
        result[percentile + "_delta_bounds_ms"] = [round(right[0] - left[1], 3), round(right[1] - left[0], 3)]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    args = parser.parse_args()
    try:
        values = []
        for path in (args.before, args.after):
            if path.stat().st_size > 1024 * 1024:
                raise ValueError("Report troppo grande.")
            values.append(json.loads(path.read_text(encoding="utf-8")))
        print(json.dumps(compare(*values), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
