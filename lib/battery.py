"""Read Linux battery figures without adding unlike charge/energy units."""
import math
from pathlib import Path
import sys


def number(path, field):
    try:
        value = float((path / field).read_text().strip())
        return value if math.isfinite(value) and value >= 0 else None
    except (OSError, ValueError):
        return None


def pair(path, first, second):
    a, b = number(path, first), number(path, second)
    return (a, b) if a is not None and b is not None and b > 0 else None


def rounded(value):
    # Match the renderer's positive f64::round(), including half percentages.
    return math.floor(value + 0.5)


def health(path):
    values = pair(path, 'energy_full', 'energy_full_design')
    values = values or pair(path, 'charge_full', 'charge_full_design')
    return None if values is None else rounded(100 * values[0] / values[1])


def summary(root):
    totals, capacities, statuses = [], [], []
    try:
        batteries = sorted(p for p in root.glob('BAT*') if p.is_dir())
    except OSError:
        batteries = []
    for path in batteries:
        try:
            statuses.append((path / 'status').read_text().strip())
        except OSError:
            pass
        capacity = number(path, 'capacity')
        if capacity is not None:
            capacities.append(capacity)
        values = pair(path, 'energy_now', 'energy_full')
        if values is not None:
            totals.append((*values, 'energy'))
            continue
        values = pair(path, 'charge_now', 'charge_full')
        if values is not None:
            voltage = number(path, 'voltage_min_design') or number(path, 'voltage_now')
            factor = voltage / 1_000_000 if voltage else 1
            totals.append((values[0] * factor, values[1] * factor,
                           'energy' if voltage else 'charge'))
    if totals:
        if len({unit for _, _, unit in totals}) > 1:
            percent = sum(100 * now / full for now, full, _ in totals) / len(totals)
        else:
            percent = 100 * sum(now for now, _, _ in totals) / sum(full for _, full, _ in totals)
    elif capacities:
        percent = sum(capacities) / len(capacities)
    else:
        return '--'
    status = next((s for s in ('Charging', 'Discharging') if s in statuses),
                  next((s for s in statuses if s), ''))
    return f'{min(100, max(0, rounded(percent)))}%  {status}'.rstrip()


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('summary', 'health'):
        raise SystemExit('usage: battery.py summary SYSFS_ROOT | health BATTERY_DIRECTORY')
    path = Path(sys.argv[2])
    if sys.argv[1] == 'summary':
        print(summary(path))
    else:
        value = health(path)
        print('--' if value is None else f'{value}%')


if __name__ == '__main__':
    main()
