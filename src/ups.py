#!/usr/bin/env python3
"""USB HID UPS monitor for Proxmox VE. Python stdlib only."""
import fcntl
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time

DISCHARGING = 0x00850045
HIDIOCGUSAGE = 0xC018480B
HIDIOCGREPORT = 0x400C4807
STATE = Path('/run/pve-ups-hid.state')
MAX_POLL_GAP = 45  # Discontinuous monitoring must never count as continuous outage.


def ups_nodes(sys_class=Path('/sys/class/usbmisc'), dev_dir=Path('/dev/usb')):
    """Find Linux hiddev nodes, without assuming a vendor/product ID or node number.

    Device eligibility is checked with a live UPS HID Discharging report below.
    """
    return [dev_dir / entry.name for entry in sorted(sys_class.glob('hiddev*'))
            if (dev_dir / entry.name).exists()]


def discharging(node):
    """Fetch FEATURE report from the device before querying its cached usage."""
    fd = os.open(str(node), os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        usage = bytearray(struct.pack('=IIIIIi', 3, 0xffffffff, 0, 0, DISCHARGING, 0))
        fcntl.ioctl(fd, HIDIOCGUSAGE, usage, True)
        report_type, report_id, *_ = struct.unpack('=IIIIIi', usage)
        # HIDIOCGREPORT is GET, not SET. It does not alter UPS settings.
        report = struct.pack('=III', report_type, report_id, 0)
        fcntl.ioctl(fd, HIDIOCGREPORT, report)
        fcntl.ioctl(fd, HIDIOCGUSAGE, usage, True)
        value = struct.unpack('=IIIIIi', usage)[5]
        if value not in (0, 1):
            raise ValueError(f'UPS 报告了异常放电状态 {value}')
        return value
    finally:
        os.close(fd)


def sample():
    """Require exactly one HID interface with a refreshable UPS Discharging bit.

    Never guess which UPS should control PVE when multiple UPS interfaces qualify.
    """
    eligible = []
    for node in ups_nodes():
        try:
            value = discharging(node)
        except (OSError, ValueError):
            # Unrelated HID devices usually do not offer UPS Discharging usage.
            continue
        eligible.append((node, value))
    if len(eligible) != 1:
        raise RuntimeError(f'发现 {len(eligible)} 个可读取放电状态的 UPS HID 接口；必须恰好 1 个')
    return eligible[0][1]


def load_state():
    try:
        state = json.loads(STATE.read_text())
        return {'since': float(state['since']), 'last': float(state['last']),
                'fired': bool(state.get('fired', False)),
                'mode': str(state.get('mode', '')), 'timeout': int(state.get('timeout', -1))}
    except (OSError, ValueError, TypeError, KeyError, OverflowError):
        return None


def clear_state():
    STATE.unlink(missing_ok=True)


def save_state(state):
    temp = STATE.with_name(STATE.name + '.tmp')
    try:
        temp.write_text(json.dumps(state, ensure_ascii=False) + '\n')
        os.replace(temp, STATE)
    finally:
        temp.unlink(missing_ok=True)


def process(value, now, state, timeout, mode):
    """Pure state machine. Returns (new_state, message, needs_shutdown)."""
    if value not in (0, 1):
        raise ValueError('未知放电状态，不得触发关机')
    if value == 0:
        return None, ('市电恢复，取消倒计时' if state else None), False
    if (state is None or state['since'] > now or state['last'] > now or
            now - state['last'] > MAX_POLL_GAP or
            state.get('mode') != mode or state.get('timeout') != timeout):
        return {'since': now, 'last': now, 'fired': False,
                'mode': mode, 'timeout': timeout}, '开始停电倒计时', False
    elapsed = now - state['since']
    updated = {'since': state['since'], 'last': now, 'fired': state['fired'],
               'mode': mode, 'timeout': timeout}
    if elapsed >= timeout and not state['fired']:
        if mode == 'dry-run':
            updated['fired'] = True
            return updated, f'模拟到期：持续停电 {int(elapsed)} 秒，不执行关机', False
        return updated, f'停电超过 {timeout} 秒，执行 PVE 正常关机', True
    return updated, f'电池供电已持续 {int(elapsed)} 秒，阈值 {timeout} 秒', False


def run():
    try:
        value = sample()
    except (OSError, ValueError, RuntimeError) as exc:
        # Unknown data is NEVER treated as battery or normal. Reset the continuous interval.
        clear_state()
        print(f'UPS 状态未知：{exc}；已取消倒计时，不会关机', file=sys.stderr, flush=True)
        return 1

    if len(sys.argv) > 1 and sys.argv[1] == 'probe':
        print(f'UPS 放电状态：{value}（{"电池供电" if value else "未放电"}）')
        return 0
    if len(sys.argv) > 1:
        print('用法：pve-ups-hid [probe]', file=sys.stderr)
        return 2

    mode = os.environ.get('UPS_MODE', 'dry-run')
    try:
        timeout = int(os.environ.get('UPS_TIMEOUT', '30'))
    except ValueError:
        print('UPS_TIMEOUT 配置无效，拒绝执行', file=sys.stderr)
        return 2
    if mode not in ('dry-run', 'live') or timeout <= 0:
        print('UPS 配置无效，拒绝执行', file=sys.stderr)
        return 2
    if mode == 'live' and timeout != 1800:
        print('真实关机模式要求 UPS_TIMEOUT=1800（30分钟），拒绝执行', file=sys.stderr)
        return 2

    now = time.monotonic()
    old_state = load_state()
    new_state, message, shutdown = process(value, now, old_state, timeout, mode)
    if new_state is None:
        clear_state()
    else:
        save_state(new_state)
    if message:
        print(message, flush=True)
    if shutdown:
        # This only runs after a confirmed battery reading and 30 min continuous monitoring.
        subprocess.run(['/usr/bin/systemctl', 'poweroff'], check=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(run())
    except Exception as exc:
        # Fail closed on all other errors too.
        print(f'UPS 监控异常，未发起关机：{exc}', file=sys.stderr)
        sys.exit(1)
