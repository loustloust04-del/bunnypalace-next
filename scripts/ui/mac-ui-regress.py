#!/usr/bin/env python3
"""冻结合成模板上的独立 mac UI 回归；不构建、不测性能、不启动默认 AUT。

父任务先 build-for-testing，并为归档 bench.app 提供一次 GREEN 隔离证明：
  scripts/ui/mac-ui-regress.sh --app /absolute/Bench.app --source-sha <sha> \
    --isolation-proof /tmp/proof.json --reuse-seed-state /tmp/seed-state.json \
    --xctestrun /absolute/MemoryPalaceTests_macosx.xctestrun \
    --deadline '2026-10-21T23:59:00-07:00' --window-approved --waive-hid

全部十项必须有真实断言回执；缺项、跳过、工具失败均不算通过。
必要证据留在自有 /private/tmp/mp-macperf-sol/bench-*-ui-*，冻结模板不改。
"""
import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SESSION = 'sol-macperf-ui'
METHOD = 'testOwnedMacRegression'
CASES = ('MK1', 'MO1', 'MP1', 'MC1', 'MC-restart', 'MC-live', 'MS1', 'MF1', 'MF2', 'MT1')
LOG_LIMIT = 768 * 1024


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


perf = module('mac_ui_perf', REPO / 'scripts/perf/mac-perf-run.py')
iso = perf.load_module('mac_ui_isolation', REPO / 'scripts/perf/mac-isolation.py')


def canonical(text, suffix=None, temporary_alias=False):
    path = Path(text)
    # 只读输入允许系统唯一的 /tmp 别名；模板 ROOT 本身仍须原规范路径。
    if temporary_alias and path.is_relative_to('/tmp'):
        path = Path('/private/tmp') / path.relative_to('/tmp')
    perf.need(path.is_absolute() and path.resolve(strict=True) == path,
              '需要规范绝对路径：' + str(path), 'BLOCKED', 78)
    perf.need(suffix is None or path.suffix == suffix, '文件类型不符：' + str(path), 'BLOCKED', 78)
    return path


def safe_file(path, root):
    perf.safe_inside(path, root)
    perf.need(not path.is_symlink(), '拒绝软链文件：' + str(path))
    return path


def write_plist(path, value):
    with path.open('xb') as handle:
        os.fchmod(handle.fileno(), 0o600)
        plistlib.dump(value, handle)


def prepare_xctestrun(source, destination, environment):
    """只保留 targetless UI bundle；冻结构建路径不随副本搬迁。"""
    perf.need(source.name.startswith('MemoryPalaceTests_'),
              '只接受 MemoryPalaceTests scheme 的冻结 xctestrun', 'BLOCKED', 78)
    perf.need(source.stat().st_size <= perf.LIMIT, 'xctestrun 超出证据边界')
    with source.open('rb') as handle:
        document = plistlib.load(handle)
    targets = []
    if 'TestConfigurations' in document:
        for configuration in document['TestConfigurations']:
            selected = [target for target in configuration.get('TestTargets', [])
                        if target.get('BlueprintName') == 'MacRegressionUITests']
            configuration['TestTargets'] = selected
            if selected:
                targets.extend(selected)
        document['TestConfigurations'] = [configuration for configuration in document['TestConfigurations']
                                          if configuration['TestTargets']]
    else:
        targets = [document['MacRegressionUITests']] if 'MacRegressionUITests' in document else []
        document = {key: value for key, value in document.items()
                    if key in ('MacRegressionUITests', '__xctestrun_metadata__')}
    perf.need(len(targets) == 1, '需要唯一 MacRegressionUITests target', 'BLOCKED', 78)
    target = targets[0]
    perf.need(target.get('IsUITestBundle') is True, '目标不是 UI test bundle', 'BLOCKED', 78)
    perf.need(not any(target.get(key) for key in
                      ('UITargetAppPath', 'UITargetAppBundleIdentifier', 'TestTargetName')),
              'UI target 必须无 AUT；禁止 Xcode 自动启动产品 App', 'BLOCKED', 78)
    # 保留 Xcode 注入的动态库搜索路径，其余宿主/凭据环境不继承。
    generated = {'DYLD_FRAMEWORK_PATH', 'DYLD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES',
                 '__XPC_DYLD_FRAMEWORK_PATH', '__XPC_DYLD_LIBRARY_PATH',
                 '__XPC_DYLD_INSERT_LIBRARIES', 'XCInjectBundleInto', 'XCTestBundlePath',
                 'XCTestConfigurationFilePath'}
    for key in ('EnvironmentVariables', 'TestingEnvironmentVariables'):
        values = {name: value for name, value in target.get(key, {}).items() if name in generated}
        target[key] = dict(values, **environment)
    target['OnlyTestIdentifiers'] = ['MacRegressionUITests/' + METHOD]
    target['SkipTestIdentifiers'] = []
    target['CommandLineArguments'] = []
    target['IsEnabled'] = True
    target['ParallelizationEnabled'] = False

    def relocate(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(source.parent))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value

    write_plist(destination, relocate(document))


class Child:
    """仅记录本次 Popen 的子树，信号前复核内核启动身份。"""
    def __init__(self, argv, environment, root, log):
        self.output = log.open('xb')
        os.fchmod(self.output.fileno(), 0o600)
        self.process = None
        self.tree = None
        self.bytes = 0
        self.next_refresh = 0
        self.closed = False
        try:
            self.process = subprocess.Popen(argv, cwd=root, env=environment,
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                            stderr=subprocess.STDOUT, start_new_session=True)
            os.set_blocking(self.process.stdout.fileno(), False)
            self.tree = iso.OwnedTree(self.process)
            self.tree.refresh()
        except BaseException:
            if self.process is not None:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait()
                self.process.stdout.close()
            self.output.close()
            raise

    def drain(self):
        while True:
            try:
                data = os.read(self.process.stdout.fileno(), 65536)
            except BlockingIOError:
                break
            if not data:
                break
            self.bytes += len(data)
            perf.need(self.bytes <= LOG_LIMIT, '自有进程输出超限；不截断成通过')
            self.output.write(data)
        self.output.flush()
        if time.monotonic() >= self.next_refresh:
            self.tree.refresh()
            self.next_refresh = time.monotonic() + 1

    def close(self):
        if self.closed:
            return
        failures = []

        def refresh():
            try:
                return self.tree.refresh()
            except Exception as error:
                if len(failures) < 8:
                    failures.append(str(error)[:2048])
                return list(self.tree.tokens)

        try:
            refresh()
            for sig in (signal.SIGTERM, signal.SIGKILL):
                self.tree.signal_owned(sig)
                end = time.monotonic() + 3
                while time.monotonic() < end:
                    self.process.poll()
                    try:
                        self.drain()
                    except Exception as error:
                        if len(failures) < 8:
                            failures.append(str(error)[:2048])
                    if not refresh():
                        break
                    time.sleep(.05)
                if not self.tree.tokens:
                    break
            perf.need(not self.tree.tokens and not self.tree.cleanup_errors and not failures,
                      '自有子树回收/有界输出失败：' + '; '.join(failures), 'RED', 70)
            self.process.wait(timeout=1)
        finally:
            self.process.stdout.close()
            self.output.close()
            self.closed = True


class Runner:
    def __init__(self, args):
        self.args = args
        self.gates = None
        self.root = self.batch = None
        self.token = None
        self.aut = self.tests = None
        self.worker = None
        self.cua_started = False
        self.root_claimed = False
        self.generation = 0
        self.last_request = None
        self.state = {'protocol': 'mac-ui-regression-v1', 'status': 'RUNNING',
                      'performanceBaseline': False, 'plannedCases': list(CASES),
                      'sourceSHA': args.source_sha.lower(), 'deadline': args.deadline,
                      'hidWaived': args.waive_hid, 'cases': [], 'cleanupErrors': []}

    def check(self):
        self.gates.window()
        self.gates.lease_alive()
        screen = self.gates.screen_state()
        perf.need(not screen['locked'] and not screen['displayAsleep'],
                  '屏幕已锁/睡眠；不绕过认证', 'BLOCKED', 78)
        if self.aut is not None:
            self.aut.drain()
            perf.need(self.aut.process.poll() is None, '自持 AUT 意外退出', 'RED', 70)
        if self.worker is not None:
            perf.need(self.worker.poll() is None, '真实 Code 写入器意外退出')

    def cua(self, operation, values=None, timeout=10, closing=False):
        arguments = dict(values or {}, session=SESSION)
        allowance = timeout if closing else max(.1, min(timeout, self.gates.remaining()))
        raw = perf.command([str(self.driver), 'call', operation, json.dumps(arguments)],
                           timeout=allowance)
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            raise perf.Stop('cua 返回无效 JSON：' + operation, 'BLOCKED', 78) from None
        perf.need(isinstance(result, dict) and not result.get('error')
                  and result.get('success') is not False and result.get('ok') is not False,
                  'cua 工具失败：' + operation, 'BLOCKED', 78)
        return result

    def start_aut(self):
        self.generation += 1
        old_guard = safe_file(self.root / 'perf/ui-main-thread.json', self.root)
        if old_guard.exists():
            old_guard.unlink()
        self.started_at = time.time()
        self.aut = Child(['/usr/bin/sandbox-exec', '-p', self.profile, str(self.binary),
                          '-lastProfileId', 'perf-bench-profile'], self.aut_env, self.root,
                         self.batch / ('aut-' + str(self.generation) + '.log'))
        self.state.setdefault('launches', []).append({'pid': self.aut.process.pid,
                                                     'startedAt': self.started_at})
        end = time.monotonic() + min(60, self.gates.remaining())
        while time.monotonic() < end:
            self.check()
            windows = self.cua('list_windows', {'pid': self.aut.process.pid}, timeout=3)
            perf.need(isinstance(windows.get('windows'), list), 'cua 窗口协议改变', 'BLOCKED', 78)
            perf.need(all(window.get('pid') == self.aut.process.pid for window in windows['windows']),
                      'cua 返回非自有窗口；不保存/操作', 'BLOCKED', 78)
            # S34 自有实物见证：主窗标题「记忆花园」、layer=0；不把弹框当主窗。
            main = [window for window in windows['windows']
                    if window.get('title') == '记忆花园' and window.get('layer') == 0]
            window = perf._app_window(main, self.aut.process.pid)
            if window is not None:
                # 精确身份仍由测试先用 NSRunningApplication 核验，再做 XCUI 查询。
                perf.atomic_json(self.batch / ('windows-' + str(self.generation) + '.json'), windows)
                self.cua('bring_to_front', {'pid': self.aut.process.pid, 'window_id': window['window_id']})
                return
            time.sleep(.2)
        raise perf.Stop('自有主窗启动超时；可能有弹框，未代点', 'BLOCKED', 124)

    def archive_guard(self):
        path = self.root / 'perf/ui-main-thread.json'
        if path.exists():
            value = perf.read_json(safe_file(path, self.root), 256 * 1024)
            perf.need(value.get('pid') == self.aut.process.pid, '主线程见证 PID 与自持 AUT 不符')
            perf.atomic_json(self.batch / ('ui-main-thread-' + str(self.generation) + '.json'), value)

    def stop_live(self):
        if self.worker is not None:
            perf.stop_worker(self.worker)
            self.worker = None

    def control(self):
        request_path = self.root / 'perf/ui-control-request.json'
        if not request_path.exists():
            return
        request = perf.read_json(safe_file(request_path, self.root), 16 * 1024)
        identifier = request.get('id')
        perf.need(isinstance(identifier, str) and 0 < len(identifier) <= 128, '无效 UI 控制请求身份')
        if identifier == self.last_request:
            return
        perf.need(len(self.state.get('controls', [])) < 32, 'UI 控制请求超出有界套件范围')
        self.last_request = identifier
        operation = request.get('operation')
        response = {'id': identifier, 'status': 'ok'}
        try:
            self.check()
            if operation == 'restart':
                self.stop_live()
                self.aut.close()
                self.archive_guard()
                self.aut = None
                self.start_aut()
            elif operation == 'start-live':
                perf.need(self.worker is None, '写入器已在运行')
                fixture = perf.read_json(self.root / 'perf/fixture.json')
                self.worker = perf.prepare_load(self.root, fixture, 'L1c', iso, self.args.protected_roots)
                perf.atomic_json(self.root / 'perf/fixture.json', fixture)
            elif operation == 'stop-live':
                self.stop_live()
            else:
                raise perf.Stop('未知 UI 控制操作')
            response.update(pid=self.aut.process.pid, startedAt=self.started_at)
            self.state.setdefault('controls', []).append({'id': identifier, 'operation': operation,
                                                          'pid': self.aut.process.pid, 'at': time.time()})
        except Exception as error:
            response.update(status='error', error=str(error)[:2048])
            perf.atomic_json(self.root / 'perf/ui-control-response.json', response)
            raise
        perf.atomic_json(self.root / 'perf/ui-control-response.json', response)

    def results(self):
        path = self.root / 'perf/ui-case-results.json'
        if path.exists():
            value = perf.read_json(safe_file(path, self.root), 256 * 1024)
            cases = value.get('cases')
            perf.need(isinstance(cases, list) and len(cases) <= len(CASES), 'UI case 回执格式/分母无效')
            names = [case.get('case') for case in cases]
            perf.need(len(set(names)) == len(names) and set(names).issubset(CASES), 'UI case 重复或未知')
            perf.need(all(case.get('status') in ('passed', 'failed', 'blocked')
                          and isinstance(case.get('failures'), list)
                          and all(isinstance(failure, str) for failure in case['failures'])
                          for case in cases), 'UI case 缺少真实状态/断言')
            self.state['cases'] = cases
            perf.atomic_json(self.batch / 'ui-case-results.json', value)
        cases = self.state['cases']
        perf.need(not any(case['status'] == 'failed' for case in cases),
                  'UI 存在失败断言', 'RED', 70)
        perf.need(not any(case['status'] == 'blocked' for case in cases),
                  'UI 有工具/认证阻断；不算产品通过', 'BLOCKED', 78)
        perf.need(len(cases) == len(CASES), 'UI 用例分母不完整；没有隐式跳过', 'INCOMPLETE', 70)
        perf.need(all(case['status'] == 'passed' and not case['failures'] for case in cases),
                  'UI passed 回执仍含失败断言', 'RED', 70)

    def run(self):
        args = self.args
        perf.need(sys.platform == 'darwin', '仅限 mac 工位', 'BLOCKED', 78)
        perf.need(re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', args.source_sha), '需要完整源码 SHA')
        expiry = dt.datetime.fromisoformat(args.deadline)
        perf.need(expiry.utcoffset() is not None and expiry.timestamp() > time.time(),
                  '授权窗口缺少时区/已过期', 'INCOMPLETE_WINDOW', 124)
        perf.need(args.window_approved and args.waive_hid, '需要显式开窗与免 HID 授权', 'BLOCKED', 78)
        app = canonical(args.app, '.app')
        self.app, self.binary, _ = perf.verify_package(args, iso)
        source = canonical(args.xctestrun, '.xctestrun', temporary_alias=True)
        seed_path = canonical(args.reuse_seed_state, '.json', temporary_alias=True)
        seed = perf.read_json(seed_path)
        perf.need(seed.get('templateFrozen') is True, '只能复用完成的冻结模板', 'BLOCKED', 78)
        self.token = seed['token']
        perf.need(isinstance(self.token, str) and re.fullmatch(r'[A-Za-z0-9_-]+', self.token), '无效模板 token')
        parent = perf.PARENT.resolve(strict=True)
        iso.private_directory(parent, parent=True)
        self.root = perf.owned_root(seed['root'], self.token)
        perf.need(self.root == parent / ('bench-' + self.token), '冻结模板绝对根改变')
        templates = perf.TEMPLATES.resolve(strict=True)
        perf.need(templates == parent / 'template', '冻结模板目录逃逸')
        iso.private_directory(templates)
        self.template = perf.owned_root(templates / self.root.name, self.token)
        iso.private_directory(self.template)
        perf.need(perf.read_json(self.template / 'perf/fixture.json').get('revision') == 'macV1-r1-fixture',
                  '冻结夹具版本不符')
        driver = shutil.which('cua-driver')
        perf.need(driver, 'cua-driver 不可达', 'BLOCKED', 78)
        self.driver = Path(driver).resolve(strict=True)
        perf.need(os.access(self.driver, os.X_OK), 'cua-driver 不可执行', 'BLOCKED', 78)
        self.batch = parent / ('bench-' + self.token + '-ui-' + uuid.uuid4().hex[:8])
        self.batch.mkdir(mode=0o700)
        perf.atomic_json(self.batch / '.mac-perf-owner.json', {'token': self.token})
        self.state.update(batch=str(self.batch), root=str(self.root), app=str(app),
                          isolationProof=str(Path(args.isolation_proof).resolve()),
                          seedReusedFrom=str(seed_path), scheme='MemoryPalaceTests',
                          xctestrun=str(source), session=SESSION)
        # 租约工具保持原会话归属；不把调用者的测试宿主/凭据环境交给 AUT。
        os.environ.update(MP_SESSION_PID='90376', MP_SESSION_ID='sol-macperf',
                          MP_ZONE_PAUSE='/nonexistent', MP_LEASE_SAY='0')
        self.gates = perf.Gates(args, iso)
        self.gates.runtime_path = self.batch / 'runtime.json'
        self.gates.wait_unlocked(self.state)
        self.gates.acquire_lease()
        self.gates.window(90)
        self.gates.lease_alive()
        if self.root.exists():
            shutil.rmtree(perf.owned_root(self.root, self.token))
        self.root_claimed = True
        perf.clone(self.template, self.root, self.token)
        for name in ('runner-home', 'runner-tmp'):
            directory = safe_file(self.root / name, self.root)
            directory.mkdir(mode=0o700, exist_ok=True)
            iso.private_directory(directory)
        self.runner_env = iso.clean_environment(self.root / 'runner-home', self.root / 'runner-tmp')
        self.runner_env.update(MP_SESSION_PID='90376', MP_SESSION_ID='sol-macperf',
                               MP_ZONE_PAUSE='/nonexistent', MP_LEASE_SAY='0', MP_XCB_SAY='0',
                               MP_XCB_FREEZE=str(Path.home() / '.mp-merge-queue/FREEZE'),
                               MP_XCB_HISTORY=str(self.batch / 'xcodebuild-history.tsv'))
        self.aut_env = iso.clean_environment(self.root / 'home', self.root / 'tmp')
        self.aut_env.update(MP_PERF_ROOT=str(self.root), MP_PERF_SEED='prepared',
                            MP_PERF_UI='1', MP_PERF_WINDOW_APPROVED='1')
        self.profile = iso.sandbox_profile(self.root, args.protected_roots)
        self.cua('start_session')
        self.cua_started = True
        self.start_aut()
        environment = dict(self.runner_env, MP_UI_BENCH_PID=str(self.aut.process.pid),
                           MP_UI_BENCH_APP=str(app), MP_UI_BENCH_ROOT=str(self.root),
                           MP_UI_FIXTURE=str(self.root / 'perf/fixture.json'), MP_UI_SESSION=SESSION,
                           MP_CUA_DRIVER=str(self.driver), MP_UI_CUA_HOME=str(Path.home()),
                           MP_UI_CONTROL_REQUEST=str(self.root / 'perf/ui-control-request.json'),
                           MP_UI_CONTROL_RESPONSE=str(self.root / 'perf/ui-control-response.json'))
        invocation = self.batch / 'MemoryPalaceTests-ui.xctestrun'
        prepare_xctestrun(source, invocation, environment)
        # xctestrun 已锁定 MemoryPalaceTests 的冻结产物；与 -scheme 混用会让 Xcode 拒绝。
        # 不拿 Gates.compile_lock，test-without-building 自己经过全局 shim。
        command = ['/bin/bash', str(REPO / 'scripts/xcodebuild-lock.sh'), 'test-without-building',
                   '-xctestrun', str(invocation), '-destination', 'platform=macOS',
                   '-parallel-testing-enabled', 'NO',
                   '-only-testing:MacRegressionUITests/MacRegressionUITests/' + METHOD,
                   '-resultBundlePath', str(self.batch / 'result.xcresult')]
        self.state['command'] = command
        self.tests = Child(command, environment, REPO, self.batch / 'test.log')
        end = time.monotonic() + min(args.timeout, self.gates.remaining())
        while self.tests.process.poll() is None:
            self.check()
            self.tests.drain()
            self.control()
            perf.need(time.monotonic() < end, 'UI 套件超时', 'TIMEOUT', 124)
            time.sleep(.1)
        self.tests.drain()
        self.state['xcodebuildExit'] = self.tests.process.returncode
        perf.need(self.tests.process.returncode == 0, 'xcodebuild UI 套件失败（见自有 test.log）')
        self.results()
        log = (self.batch / 'test.log').read_text(errors='replace')
        passed = re.findall(r"Test Case ['\"]([^\n]*" + METHOD + r"[^\n]*)['\"] passed", log)
        perf.need(len(passed) == 1, '缺少唯一 XCTest 真通过回执；不以 exit0 替代', 'INCOMPLETE', 70)
        perf.need((self.batch / 'result.xcresult').is_dir(), 'XCTest 结果包缺失', 'INCOMPLETE', 70)
        self.state['status'] = 'GREEN'
        return 0

    def close(self):
        errors = self.state['cleanupErrors']
        for child in (self.tests, self.aut):
            if child is not None:
                try:
                    child.close()
                    if child is self.aut:
                        self.archive_guard()
                except Exception as error:
                    errors.append(type(error).__name__ + ': ' + str(error)[:2048])
        try:
            self.stop_live()
        except Exception as error:
            errors.append('writer: ' + str(error)[:2048])
        if self.cua_started:
            try:
                # 截止后仍允许结束自己的 session，绝不启动新交互。
                self.cua('end_session', timeout=10, closing=True)
            except Exception as error:
                errors.append('cua: ' + str(error)[:2048])
            self.cua_started = False
        if self.root_claimed:
            try:
                result = self.root / 'perf/ui-case-results.json'
                if result.exists():
                    value = perf.read_json(safe_file(result, self.root), 256 * 1024)
                    perf.atomic_json(self.batch / 'ui-case-results.json', value)
                    self.state['cases'] = value.get('cases', [])
                if not errors:
                    shutil.rmtree(perf.owned_root(self.root, self.token))
                else:
                    self.state['retainedRoot'] = str(self.root)
            except Exception as error:
                errors.append('owned root: ' + str(error)[:2048])
        if self.gates is not None:
            try:
                self.gates.close(self.state)
            except Exception as error:
                errors.append('lease: ' + str(error)[:2048])
            self.state['lastScreen'] = self.gates.last_screen
        if errors:
            self.state['status'] = 'RED'
        self.state['endedAt'] = time.time()
        if self.batch is not None:
            perf.atomic_json(self.batch / 'summary.json', self.state)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for option in ('app', 'source-sha', 'isolation-proof', 'reuse-seed-state', 'xctestrun', 'deadline'):
        parser.add_argument('--' + option, required=True)
    parser.add_argument('--window-approved', action='store_true', required=True)
    parser.add_argument('--waive-hid', action='store_true', required=True)
    parser.add_argument('--timeout', type=int, default=1800, help='套件墙钟上限秒数（仍受授权截止限制）')
    args = parser.parse_args()
    runner = Runner(args)
    handlers = {}

    def interrupted(signum, frame):
        raise perf.Stop('UI 运行被中断', 'INTERRUPTED', 130)

    for sig in (signal.SIGINT, signal.SIGTERM):
        handlers[sig] = signal.signal(sig, interrupted)
    code = 70
    try:
        perf.need(0 < args.timeout <= 7200, '套件 timeout 必须在 1..7200 秒')
        code = runner.run()
    except (perf.Stop, iso.Failure) as error:
        runner.state.update(status=getattr(error, 'status', 'RED'), error=str(error))
        code = error.code
    except Exception as error:
        runner.state.update(status='RED', error=type(error).__name__ + ': ' + str(error)[:2048])
    finally:
        # 第二次终止也不能打断自有子树和租约回收。
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        try:
            runner.close()
        except Exception as error:
            runner.state.update(status='RED', error='收尾失败：' + str(error)[:2048])
            code = 70
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    if runner.state['status'] != 'GREEN' and code == 0:
        code = 70
    print(json.dumps({'status': runner.state['status'], 'summary': str(runner.batch / 'summary.json')
                      if runner.batch is not None else None, 'error': runner.state.get('error'),
                      'completedCases': len(runner.state['cases']), 'plannedCases': len(CASES)}, ensure_ascii=False))
    return code


if __name__ == '__main__':
    sys.exit(main())
