#!/bin/sh
# PVE UPS HID 一键安装：全新系统默认真实关机；旧配置保留，可 --upgrade 仅升级监控核心。
set -eu
umask 022

fail() { printf '%s\n' "错误：$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail '请使用 root 运行。'
[ -x /usr/bin/python3 ] || fail '未找到 /usr/bin/python3。'
[ -d /run/systemd/system ] || fail '当前系统未运行 systemd。'

case "${1-}" in ''|--upgrade) ;; *) fail '用法：sh install.sh [--upgrade]' ;; esac
upgrade=0
[ "${1-}" = '--upgrade' ] && upgrade=1

CORE=/usr/local/sbin/pve-ups-hid
MENU=/usr/local/bin/pve-ups
CONFIG=/etc/default/pve-ups-hid
SERVICE=/etc/systemd/system/pve-ups-hid.service
TIMER=/etc/systemd/system/pve-ups-hid.timer

# 禁止部分已安装时覆盖文件，避免破坏正在运行的 UPS 保护。
any_existing=0
all_existing=1
for f in "$CORE" "$CONFIG" "$SERVICE" "$TIMER"; do
    [ -e "$f" ] && any_existing=1 || all_existing=0
done
if [ "$any_existing" -eq 1 ] && [ "$all_existing" -ne 1 ]; then
    fail '检测到部分旧安装文件。为保护已有配置，未修改系统。请先人工检查 /etc/default/pve-ups-hid 和两个 systemd unit。'
fi
[ -L "$MENU" ] && fail '发现已有符号链接 /usr/local/bin/pve-ups，拒绝覆盖。'
[ -e "$MENU" ] && [ "$all_existing" -eq 0 ] && fail '已存在 /usr/local/bin/pve-ups，但 UPS 核心尚未安装；拒绝覆盖。'

# 代码与安装器合为一份：无需 wget/git/pip，无需在线下载第二个文件。
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$tmpdir/pve-ups-hid" <<'PY_MONITOR'
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
PY_MONITOR
cat > "$tmpdir/pve-ups" <<'PY_MENU'
#!/usr/bin/env python3
"""PVE UPS HID 管理入口。只管理已经安装的 pve-ups-hid v2，不修改监控核心。"""
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

BIN = '/usr/local/sbin/pve-ups-hid'
CONF = Path('/etc/default/pve-ups-hid')
TIMER = 'pve-ups-hid.timer'
SERVICE = 'pve-ups-hid.service'
DROPIN = Path('/etc/systemd/system/pve-ups-hid.timer.d/10-interval.conf')
STATE = Path('/run/pve-ups-hid.state')


class ConfigError(Exception):
    pass


def cmd(*args, check=True, timeout=12, capture=False):
    return subprocess.run(args, check=check, timeout=timeout,
                          text=True, capture_output=capture)


def require_installed():
    if os.geteuid() != 0:
        raise ConfigError('请使用 root 执行该命令')
    if not Path(BIN).is_file() or not CONF.is_file():
        raise ConfigError('未发现已安装的 pve-ups-hid v2；未修改任何文件')
    if not Path('/etc/systemd/system/pve-ups-hid.timer').is_file():
        raise ConfigError('未发现 pve-ups-hid.timer；未修改任何文件')


def settings():
    content = CONF.read_text(encoding='utf-8')
    values = {}
    for key in ('UPS_MODE', 'UPS_TIMEOUT'):
        found = re.findall(r'^' + key + r'=([^\n#]*)$', content, re.M)
        if len(found) != 1:
            raise ConfigError(f'{CONF} 中 {key} 不存在或有重复配置，请先人工检查')
        values[key] = found[0].strip()
    if values['UPS_MODE'] not in ('dry-run', 'live'):
        raise ConfigError('配置中的 UPS_MODE 无效')
    try:
        seconds = int(values['UPS_TIMEOUT'])
    except ValueError as exc:
        raise ConfigError('配置中的 UPS_TIMEOUT 无效') from exc
    if seconds < 1 or (values['UPS_MODE'] == 'live' and seconds != 1800):
        raise ConfigError('配置不符合监控程序要求：正式模式只能使用1800秒')
    return content, values['UPS_MODE'], seconds


def read_ups():
    r = cmd(BIN, 'probe', check=False, timeout=8, capture=True)
    output = (r.stdout + r.stderr).strip()
    if r.returncode:
        raise ConfigError(f'UPS 检测失败：{output or "无错误详情"}')
    m = re.search(r'UPS 放电状态：([01])（', output)
    if not m:
        raise ConfigError(f'无法识别 UPS 探测输出：{output}')
    return int(m.group(1))


def power_guard():
    power = read_ups()
    if power != 0:
        raise ConfigError('UPS 当前正在电池供电；请恢复市电后再修改此项')


def atomic_write(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.pve-ups-', dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def update_config(mode, timeout):
    original, old_mode, old_timeout = settings()
    if old_mode == mode and old_timeout == timeout:
        print('配置没有变化。')
        return
    updated = re.sub(r'^UPS_MODE=[^\n]*$', 'UPS_MODE=' + mode, original, count=1, flags=re.M)
    updated = re.sub(r'^UPS_TIMEOUT=[^\n]*$', 'UPS_TIMEOUT=' + str(timeout), updated,
                     count=1, flags=re.M)
    # 留一份独立备份，不覆盖用户之前的 .bak
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup = CONF.with_name(CONF.name + '.menu-bak-' + stamp)
    shutil.copy2(CONF, backup)
    mode_bits = stat.S_IMODE(CONF.stat().st_mode)
    atomic_write(CONF, updated, mode_bits)
    print(f'已更新：{CONF}')
    print(f'修改前备份：{backup}')
    print('下一个监控周期生效；修改模式或阈值后，原倒计时会重新计算。')


def change_live():
    _, mode, timeout = settings()
    if mode == 'live' and timeout == 1800:
        print('当前已是正式模式：连续停电30分钟触发 PVE 正常关机。')
        return
    power_guard()
    print('警告：启用后，连续停电30分钟将实际关闭整个 PVE！')
    if input('请输入“启用真实关机”以确认：').strip() != '启用真实关机':
        print('已取消。')
        return
    power_guard()  # 确认前后各检查一次，尽量避免停电期间切换
    update_config('live', 1800)


def change_dry():
    _, mode, timeout = settings()
    if mode == 'dry-run':
        print(f'当前已是模拟模式，模拟阈值 {timeout} 秒。')
        return
    update_config('dry-run', 30)
    print('已切到模拟模式；到期只记录日志，不会关机。')


def change_sim_timeout(n):
    if not (5 <= n <= 3600):
        raise ConfigError('模拟阈值允许5～3600秒')
    _, mode, _ = settings()
    if mode != 'dry-run':
        raise ConfigError('当前是真实关机模式，请先切换至模拟模式再调整模拟阈值')
    update_config('dry-run', n)


def change_interval(n):
    if not (5 <= n <= 20):
        raise ConfigError('检测间隔允许5～20秒；更长的间隔可能触发45秒连续性保护')
    power_guard()
    timer_was_active = cmd('systemctl', 'is-active', TIMER, check=False,
                           capture=True).returncode == 0
    old = DROPIN.read_bytes() if DROPIN.exists() else None
    old_mode = stat.S_IMODE(DROPIN.stat().st_mode) if DROPIN.exists() else 0o644
    new = ('[Timer]\nOnUnitInactiveSec=\n'
           f'OnUnitInactiveSec={n}s\n')
    atomic_write(DROPIN, new, old_mode)
    try:
        cmd('systemctl', 'daemon-reload')
        # 只更新已经在运行的定时器；已暂停的监控不得被意外启动
        if timer_was_active:
            cmd('systemctl', 'restart', TIMER)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        if old is None:
            DROPIN.unlink(missing_ok=True)
        else:
            atomic_write(DROPIN, old.decode('utf-8'), old_mode)
        cmd('systemctl', 'daemon-reload', check=False)
        if timer_was_active:
            cmd('systemctl', 'restart', TIMER, check=False)
        raise ConfigError('定时器更新失败，已尝试恢复原配置；请检查 systemctl status')
    print(f'监测间隔已设为 {n} 秒；timer 已重新加载。')
    print('若当前正在倒计时，改变间隔可能导致计时重置。')


def timer_interval():
    # systemd cat 输出原配置以及 drop-in；后出现的取代前者
    r = cmd('systemctl', 'cat', TIMER, check=False, timeout=8, capture=True)
    vals = re.findall(r'^OnUnitInactiveSec=(\d+)s\s*$', r.stdout, re.M)
    return (vals[-1] + ' 秒') if vals else '未知'


def status():
    _, mode, seconds = settings()
    label = '真实关机' if mode == 'live' else '模拟（绝不会因阈值触发关机）'
    print('\n===== PVE UPS 管理状态 =====')
    print('模式：', label)
    print(f'停电阈值：{seconds} 秒（{seconds / 60:g} 分钟）')
    print('检测间隔：', timer_interval())
    for what, args in [('开机自启', ('systemctl', 'is-enabled', TIMER)),
                       ('当前定时器', ('systemctl', 'is-active', TIMER))]:
        r = cmd(*args, check=False, timeout=8, capture=True)
        print(f'{what}：{r.stdout.strip() or "未知"}')
    try:
        value = read_ups()
        print('UPS：', '正在电池供电' if value else '未放电（通常为市电正常）')
    except (ConfigError, subprocess.TimeoutExpired) as exc:
        print(f'UPS：读取失败：{exc}')
    try:
        data = json.loads(STATE.read_text())
        last = time.monotonic() - float(data['last'])
        if (0 <= last <= 45 and data.get('mode') == mode and
                int(data.get('timeout', -1)) == seconds):
            elapsed = max(0, int(time.monotonic() - float(data['since'])))
            print(f'倒计时：已记录 {elapsed} 秒；剩余约 {max(0, seconds - elapsed)} 秒')
        else:
            print('倒计时：状态已过期，须以监控服务下一次输出为准')
    except (OSError, ValueError, TypeError, KeyError):
        print('倒计时：无有效记录')
    print('===========================\n')


def pause():
    print('注意：停用定时器后，PVE 将不再受 UPS 自动关机保护！')
    if input('请输入“暂停UPS保护”确认：').strip() != '暂停UPS保护':
        print('已取消。')
        return
    cmd('systemctl', 'disable', '--now', TIMER)
    print('已停用监控及开机自启。')


def resume():
    # 恢复监控不应依赖市电存在，停电期间也应允许恢复保护。
    cmd('systemctl', 'enable', '--now', TIMER)
    print('已启用监控及开机自启。')


def logs():
    cmd('journalctl', '-u', SERVICE, '-n', '35', '--no-pager', '-o', 'cat', check=False)


def menu():
    options = '''\n==== PVE UPS 统一管理 ====\n1. 查看运行状态\n2. 读取 UPS 实时状态\n3. 启用真实关机（停电30分钟）\n4. 切换模拟模式（不关机）\n5. 修改模拟倒计时（5～3600秒）\n6. 修改监测间隔（5～20秒）\n7. 查看最近35条日志\n8. 暂停监控（危险操作）\n9. 恢复监控\n0. 退出\n请选择：'''
    while True:
        try:
            choice = input(options).strip()
            if choice == '0':
                return
            if choice == '1':
                status()
            elif choice == '2':
                value = read_ups()
                print('UPS 当前：', '电池供电' if value else '未放电')
            elif choice == '3':
                change_live()
            elif choice == '4':
                change_dry()
            elif choice == '5':
                change_sim_timeout(int(input('模拟倒计时秒数：').strip()))
            elif choice == '6':
                change_interval(int(input('监测间隔秒数：').strip()))
            elif choice == '7':
                logs()
            elif choice == '8':
                pause()
            elif choice == '9':
                resume()
            else:
                print('无效选项。')
        except (ConfigError, OSError, ValueError, subprocess.CalledProcessError,
                subprocess.TimeoutExpired) as exc:
            print(f'操作未完成：{exc}', file=sys.stderr)
        except (EOFError, KeyboardInterrupt):
            print('\n已退出。')
            return


def main(argv):
    require_installed()
    if not argv or argv == ['config']:
        menu()
    elif argv == ['status']:
        status()
    elif argv == ['probe']:
        print('UPS 当前：', '电池供电' if read_ups() else '未放电')
    elif argv == ['logs']:
        logs()
    elif argv == ['dry-run']:
        change_dry()
    elif argv == ['live']:
        change_live()
    elif len(argv) == 2 and argv[0] == 'interval':
        change_interval(int(argv[1]))
    elif len(argv) == 2 and argv[0] == 'simulate':
        change_sim_timeout(int(argv[1]))
    elif argv == ['pause']:
        pause()
    elif argv == ['resume']:
        resume()
    else:
        print('用法：pve-ups [config|status|probe|logs|dry-run|live|simulate 秒|interval 秒|pause|resume]',
              file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (ConfigError, OSError, ValueError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as e:
        print(f'未完成：{e}', file=sys.stderr)
        sys.exit(1)
PY_MENU
chmod 0755 "$tmpdir/pve-ups-hid" "$tmpdir/pve-ups"
/usr/bin/python3 -m py_compile "$tmpdir/pve-ups-hid" "$tmpdir/pve-ups" || fail 'Python 代码检查失败。'

if [ "$upgrade" -eq 1 ] && [ "$all_existing" -eq 0 ]; then
    fail '--upgrade 只能用于已完整安装的 PVE；全新安装请不带参数。'
fi

if [ "$all_existing" -eq 1 ]; then
    # 已安装默认不修改。--upgrade 仅备份并替换监控核心，绝不改配置/menu/unit。
    [ -f "$CORE" ] && [ -f "$SERVICE" ] && [ -f "$TIMER" ] && [ -f "$CONFIG" ] || fail '发现旧安装文件类型异常，请人工检查。'
    if [ "$upgrade" -eq 1 ]; then
        probe_out=$(/usr/bin/python3 "$tmpdir/pve-ups-hid" probe) || fail '新版 UPS 探测失败，原安装保持不变。'
        case "$probe_out" in
            *'UPS 放电状态：0（未放电）'*) ;;
            *) fail '新版 UPS 非正常供电状态，拒绝升级；原安装保持不变。' ;;
        esac
        backup="$CORE.backup-$(date +%Y%m%d-%H%M%S)"
        [ ! -e "$backup" ] || fail "备份文件已存在：$backup"
        cp -p "$CORE" "$backup" || fail '原监控程序备份失败；未升级。'
        new_core="$CORE.new-$"
        if ! install -m 0755 "$tmpdir/pve-ups-hid" "$new_core"; then
            rm -f "$new_core"
            fail '新版监控文件暂存失败，原安装保持不变。'
        fi
        if ! mv -f "$new_core" "$CORE"; then
            rm -f "$new_core"
            fail '新版监控替换失败；请检查原文件和备份。'
        fi
        printf '已仅升级监控核心；原程序备份：%s\n' "$backup"
        printf '%s\n' '未改变原运行模式、倒计时、timer 和管理菜单。'
        exit 0
    fi
    if [ ! -e "$MENU" ]; then
        install -m 0755 "$tmpdir/pve-ups" "$MENU"
        printf '%s\n' '已补齐中文管理命令 pve-ups。'
    else
        printf '%s\n' '已检测到完整安装；不覆盖现有 Python 代码、菜单、配置及 systemd 定时器。'
    fi
    printf '%s\n' '提示：保留了当前 live/dry-run 模式、倒计时、监测间隔、开机自启状态。'
    printf '%s\n' '使用 pve-ups status 查看当前运行状态。'
    exit 0
fi

# 全新安装：要求恰好一个可用 UPS，且能主动刷新并确认当前未放电。
probe_out=$(/usr/bin/python3 "$tmpdir/pve-ups-hid" probe) || fail 'UPS 主动刷新探测失败。未安装任何文件。'
printf '%s\n' "$probe_out"
case "$probe_out" in
    *'UPS 放电状态：0（未放电）'*) ;;
    *) fail 'UPS 当前正在放电或状态无法确认。为防止直接进入真实模式，未安装任何文件。' ;;
esac
install -m 0755 "$tmpdir/pve-ups-hid" "$CORE"
install -m 0755 "$tmpdir/pve-ups" "$MENU"
cat > "$CONFIG" <<'UPS_CONFIG'
# live: 连续停电 1800 秒触发 PVE 正常关机；dry-run: 到期只记录日志
UPS_MODE=live
# 真实模式固定为 1800 秒（30 分钟）
UPS_TIMEOUT=1800
UPS_CONFIG
chmod 0644 "$CONFIG"
cat > "$SERVICE" <<'UPS_SERVICE'
[Unit]
Description=UPS USB HID Monitor (Python stdlib)
After=local-fs.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/pve-ups-hid
ExecStart=/usr/local/sbin/pve-ups-hid
TimeoutStartSec=8s
UPS_SERVICE
cat > "$TIMER" <<'UPS_TIMER'
[Unit]
Description=UPS HID monitor every 10 seconds

[Timer]
OnBootSec=30s
OnUnitInactiveSec=10s
AccuracySec=1s
Unit=pve-ups-hid.service

[Install]
WantedBy=timers.target
UPS_TIMER
chmod 0644 "$SERVICE" "$TIMER"
systemctl daemon-reload
systemctl enable --now pve-ups-hid.timer
printf '\n%s\n' '安装完成：默认正式模式，连续停电 1800 秒后会请求 PVE 关机。'
printf '%s\n' '管理菜单：pve-ups'
printf '%s\n' '实时状态：pve-ups status'
printf '%s\n' '注意：若旧 CT 202 仍运行 UPS 监控，请先停止旧服务，避免双重关机控制。'
