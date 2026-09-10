"""Run the settings battery paths against temporary sysfs-shaped fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SettingsBattery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="null-battery-test-")
        self.addCleanup(self.temp.cleanup)
        self.sysfs = Path(self.temp.name)

    def battery(self, name, **values):
        path = self.sysfs / name
        path.mkdir()
        for key, value in values.items():
            (path / key).write_text(str(value))
        return path

    def settings(self, detail=False):
        source = (ROOT / "bin/null-settings").read_text()
        if detail:
            block = source.split('    BATTERY) say "battery"', 1)[1].split('    LID-CLOSE)', 1)[0]
            code = 'say() { printf "%s\\n" "$@"; }; fixture() { case BATTERY in\n'
            code += 'BATTERY) say "battery"' + block + '\nesac; }; fixture'
        else:
            code = 'read_battery() {' + source.split('read_battery() {', 1)[1].split('read_firewall()', 1)[0]
            code += '\nread_battery\n'
        code = code.replace('/sys/class/power_supply', str(self.sysfs))
        result = subprocess.run(['bash', '-c', code], capture_output=True, text=True,
                                env=dict(os.environ, ROOT=str(ROOT), NULL_UNMEASURED='--'), timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_mixed_charge_and_energy_are_converted_before_summing(self):
        self.battery('BAT0', charge_now=9000000, charge_full=10000000,
                     voltage_now=10000000, status='Discharging')
        self.battery('BAT1', energy_now=20000000, energy_full=40000000, status='Discharging')
        self.assertEqual(self.settings().strip(), '79%  Discharging')

    def test_unreconciled_units_average_percentages(self):
        self.battery('BAT0', charge_now=9000000, charge_full=10000000, status='Discharging')
        self.battery('BAT1', energy_now=20000000, energy_full=40000000, status='Discharging')
        self.assertEqual(self.settings().strip(), '70%  Discharging')

    def test_health_uses_a_matched_charge_pair_when_energy_design_is_absent(self):
        self.battery('BAT0', energy_full=80000000, charge_full=8000000,
                     charge_full_design=10000000, capacity=80, status='Full')
        health = [line.split()[-1] for line in self.settings(detail=True).splitlines() if 'health' in line]
        self.assertEqual(health, ['80%'])

    def test_missing_measurements_are_unmeasured(self):
        self.assertEqual(self.settings().strip(), '--')
        self.battery('BAT0', energy_now='nan', energy_full=0, status='Unknown')
        self.assertEqual(self.settings().strip(), '--')


if __name__ == '__main__':
    unittest.main()
