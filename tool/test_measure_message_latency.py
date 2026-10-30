import unittest
from unittest.mock import patch

from measure_message_latency import (MeasurementError, Snapshot, center, latency_bounds,
                                     measure_sample, parse_hierarchy, report, validate_chat,
                                     NotificationSnapshot, notification_signatures, measure_transition)
from compare_message_latency import compare


def hierarchy(title="Peer", draft="", probe=""):
    return parse_hierarchy(f'''ignored prefix <?xml version="1.0"?>
      <hierarchy><node package="com.sylphy" text="{title}" />
      <node package="com.sylphy" class="android.widget.EditText" text="{draft}" bounds="[0,100][100,150]" />
      <node package="com.sylphy" content-desc="Invia messaggio" bounds="[100,100][150,150]" />
      <node package="com.sylphy" text="{probe}" /></hierarchy>dump status''')


class LatencyTests(unittest.TestCase):
    def test_state_changing_scenarios_require_explicit_consent_before_any_adb_action(self):
        for scenario in ('screen-off', 'network-change', 'invalid'):
            with self.assertRaises(MeasurementError):
                measure_sample(object(), 'A', 'B', 'B', 'A', 60, .25, scenario)
    def test_notification_observer_only_uses_active_sylphy_message_metadata(self):
        output = '''Notification List:
  NotificationRecord(0x123 pkg=com.other id=4105 key=other:private)
    channel=sylphy_messages postTime=123
  NotificationRecord(0x234 pkg=com.sylphy id=4104 key=service)
    channel=sylphy_background_messaging postTime=123
  NotificationRecord(0x345 pkg=com.sylphy id=4105 key=test-conversation)
    channel=sylphy_messages postTime=123 mUpdateTimeMs=456
Historical Notification List:
  NotificationRecord(0x456 pkg=com.sylphy id=4105 key=old-conversation)
    channel=sylphy_messages postTime=1
'''
        result = notification_signatures(output)
        self.assertEqual(result, frozenset({"test-conversation|123|456"}))
        self.assertEqual(result, notification_signatures(output.replace('0x345', '0x999')))
        with self.assertRaises(MeasurementError):
            notification_signatures('unrecognized vendor dump')

    def test_screen_off_observes_notification_changes_and_always_restores_screen(self):
        class FakeAdb:
            def __init__(self): self.screens = []; self.fail = False; self.observations = 0
            def interactive(self, serial): return not self.screens
            def screen(self, serial, awake): self.screens.append(awake)
            def notifications(self, serial):
                self.observations += 1
                return NotificationSnapshot(frozenset({str(self.observations)}), 11, 12)
            def tap(self, serial, send):
                if self.fail: raise MeasurementError('simulated failure')
        adb = FakeAdb()
        with patch('measure_message_latency.time.monotonic', return_value=10):
            sample = measure_transition(adb, 'A', 'B', None, Snapshot(hierarchy(), 1, 2), 60, .25, 'probe', 'screen-off')
        self.assertEqual(adb.screens, [False, True])
        self.assertEqual(sample['outcome'], 'notification_changed')
        result = report([sample], 'screen-off')
        self.assertEqual(result['visible'], 0)
        self.assertEqual(result['notifications_observed'], 1)
        self.assertEqual(result['percentiles_population'], 'notification_changes_only')
        adb = FakeAdb(); adb.fail = True
        with self.assertRaises(MeasurementError):
            measure_transition(adb, 'A', 'B', None, Snapshot(hierarchy(), 1, 2), 60, .25, 'probe', 'screen-off')
        self.assertEqual(adb.screens, [False, True])

    def test_wifi_is_restored_after_handover_even_when_observation_fails(self):
        class FakeAdb:
            def __init__(self): self.changes = []
            def wifi_enabled(self, serial): return True
            def mobile_data_ready(self, serial): return True
            def wifi(self, serial, enabled): self.changes.append(enabled)
            def tap(self, serial, send): pass
            def snapshot(self, serial): raise MeasurementError('simulated failure')
        adb = FakeAdb()
        with patch('measure_message_latency.time.monotonic', return_value=10), self.assertRaises(MeasurementError):
            measure_transition(adb, 'A', 'B', None, Snapshot(hierarchy(), 1, 2), 60, .25, 'probe', 'network-change')
        self.assertEqual(adb.changes, [False, True])

    def test_comparison_preserves_uncertainty_and_refuses_mixed_observations(self):
        before = report([{'outcome': 'visible', 'lower_bound_ms': 100, 'upper_bound_ms': 500}])
        after = report([{'outcome': 'visible', 'lower_bound_ms': 50, 'upper_bound_ms': 250}])
        self.assertEqual(compare(before, after)['p50_delta_bounds_ms'], [-450, 150])
        with self.assertRaises(ValueError): compare(before, report([], 'screen-off'))
        self.assertIsNone(compare(report([]), report([]))['p95_delta_bounds_ms'])
        with self.assertRaises(ValueError): compare({**before, 'incomplete': True}, after)
    def test_hierarchy_is_parsed_in_memory_and_ambiguous_or_private_other_apps_are_rejected(self):
        snapshot = Snapshot(hierarchy(), 1, 2)
        editor, send = validate_chat(snapshot, "Peer")
        self.assertEqual(center(send), (125, 125))
        self.assertEqual(center(editor), (50, 125))
        for output in ("", "<hierarchy>bad", "<hierarchy><node></hierarchy>"):
            with self.assertRaises(MeasurementError):
                parse_hierarchy(output)
        with self.assertRaises(MeasurementError):
            validate_chat(snapshot, "Wrong contact")
        with self.assertRaises(MeasurementError):
            validate_chat(Snapshot(hierarchy(draft="Unsent private draft"), 1, 2), "Peer")
        snapshot.root.append(send)
        with self.assertRaises(MeasurementError):
            validate_chat(snapshot, "Peer")

    def test_bounds_include_send_and_snapshot_uncertainty_without_phone_clock_synchronization(self):
        absent = Snapshot(hierarchy(), 10.5, 11)
        present = Snapshot(hierarchy(), 12, 13)
        self.assertEqual(latency_bounds(10, 10.2, absent, present), (300, 3000))
        self.assertEqual(latency_bounds(10, 10.2, Snapshot(hierarchy(), 9, 9.5), present), (0, 3000))

    def test_real_ui_workflow_sends_once_and_reports_bounds_without_contact_or_probe_contents(self):
        probe = "SylphyProbe_" + "a" * 24
        class FakeAdb:
            def __init__(self):
                self.snapshots = {"A": [Snapshot(hierarchy("B"), 1, 2),
                                         Snapshot(hierarchy("B", draft=probe), 8, 9)],
                                  "B": [Snapshot(hierarchy("A"), 6, 7),
                                         Snapshot(hierarchy("A", probe=probe), 11, 12)]}
                self.typed = []
                self.taps = []
            def snapshot(self, serial): return self.snapshots[serial].pop(0)
            def tap(self, serial, node): self.taps.append(serial)
            def type_probe(self, serial, text): self.typed.append((serial, text))
        adb = FakeAdb()
        with patch("measure_message_latency.secrets.token_hex", return_value="a" * 24), \
             patch("measure_message_latency.time.monotonic", side_effect=[10, 10.2, 10.3]):
            sample = measure_sample(adb, "A", "B", "B", "A", 60, .25)
        self.assertEqual(adb.typed, [("A", probe)])
        self.assertEqual(adb.taps, ["A", "A"])
        self.assertEqual(sample["outcome"], "visible")
        self.assertEqual(sample["lower_bound_ms"], 0)
        self.assertEqual(sample["upper_bound_ms"], 2000)
        self.assertNotIn(probe, str(report([sample])))

    def test_timeouts_remain_counted_and_do_not_become_zero_latency_samples(self):
        samples = [{"outcome": "visible", "lower_bound_ms": 100, "upper_bound_ms": 500},
                   {"outcome": "timeout", "timeout_seconds": 60}]
        result = report(samples)
        self.assertEqual(result["attempted"], 2)
        self.assertEqual(result["timed_out"], 1)
        self.assertEqual(result["visible"], 1)
        self.assertEqual(result["p95_bounds_ms"], [100, 500])
        self.assertEqual(result["percentiles_population"], "visible_samples_only")
        self.assertNotIn("p50_bounds_ms", report([samples[1]]))


if __name__ == "__main__":
    unittest.main()
