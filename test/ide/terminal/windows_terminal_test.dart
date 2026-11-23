@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show windowsAppExecutionAliasExists;
import 'package:baocode/ide/terminal/pty.dart';
import 'package:baocode/ide/terminal/terminal_profile_versions_windows.dart';
import 'package:baocode/ide/terminal/terminal_profiles.dart';
import 'package:baocode/ide/terminal/terminal_shell.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final base = Platform.environment;
  final local = base['LOCALAPPDATA'];
  final aliases = [
    if (local != null)
      for (final folder in ['', 'Microsoft.PowerShell_8wekyb3d8bbwe'])
        p.join(local, 'Microsoft', 'WindowsApps', folder, 'pwsh.exe'),
  ].where(windowsAppExecutionAliasExists).toList();
  final legacy = windowsPowerShell(base);

  tearDown(() => ClaudeEnvironment.use(null));

  test('reads legacy version and leaves an unknown executable alone', () async {
    final installed = TerminalProfile(name: 'Windows PowerShell', path: legacy);
    final dir = await Directory.systemTemp.createTemp('baocode-metadata');
    addTearDown(() => dir.delete());
    final missing = TerminalProfile(
      name: 'PowerShell',
      path: p.join(dir.path, '未安装 [PowerShell]', 'pwsh.exe'),
    );
    final enriched = await withWindowsTerminalProfileVersions([
      installed,
      missing,
    ]);
    expect(enriched.first.displayName, 'PowerShell（5.1）');
    expect(enriched.first.shell, installed.shell);
    expect(enriched.last, same(missing));
  }, skip: !File(legacy).existsSync());

  test(
    'Store aliases work in explicit profiles and automatic discovery',
    () async {
      for (final alias in aliases) {
        ClaudeEnvironment.use({
          'SystemRoot': base['SystemRoot']!,
          'Path': p.dirname(alias),
        });
        final profiles = await terminalProfiles(
          configured: {
            'Store': {
              'path': alias,
              'args': ['-NoLogo'],
            },
          },
        );
        final configured = profiles.profiles.singleWhere(
          (profile) => profile.name == 'Store',
        );
        expect(configured.args, ['-NoLogo']);
        if (File(legacy).existsSync()) {
          expect(configured.version, matches(r'^\d+\.\d+\.\d+(?:\.\d+)?$'));
        }
        expect(profiles.systemShell.executable, alias);
        final dir = Directory.systemTemp.createTempSync('baocode-pwsh');
        addTearDown(() => dir.deleteSync());
        final pty = await spawnPty(
          PtyLaunch(
            executable: alias,
            arguments: ['-NoProfile', '-Command', r'$PSVersionTable.PSEdition'],
            workingDirectory: dir.path,
          ),
        );
        addTearDown(() => pty.kill());
        final output = utf8.decoder.bind(pty.output).join();
        expect(await pty.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(await output, contains('Core'));
      }
    },
    skip: aliases.isEmpty
        ? 'PowerShell Store aliases are not installed'
        : false,
  );

  test(
    'preflight respects the child policy without loading the profile',
    () async {
      ClaudeEnvironment.use(base);
      final groupPolicy = await Process.run(legacy, [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"[bool](Get-ExecutionPolicy -List | Where-Object { $_.Scope -in 'MachinePolicy','UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined' })",
      ]);
      expect(groupPolicy.exitCode, 0);
      if (groupPolicy.stdout.toString().trim() == 'True') return;
      const policyKey = 'PSExecutionPolicyPreference';
      Future<({PtyLaunch launch, WindowsProfilePolicy? policy})> prepare(
        String value,
      ) => prepareInteractiveTerminalLaunch(
        Directory.systemTemp.path,
        columns: 80,
        rows: 24,
        shell: (executable: legacy, arguments: const []),
        environment: TerminalEnvironmentRequest(
          env: {
            for (final key in base.keys)
              if (key.toUpperCase() == policyKey.toUpperCase()) key: null,
            policyKey: value,
          },
        ),
      );
      final allowed = await prepare('RemoteSigned');
      expect(allowed.policy, isNull);
      expect(allowed.launch.arguments, isNot(contains('-NoProfile')));
      final restricted = await prepare('Restricted');
      expect(restricted.launch.arguments, isEmpty);
      if (restricted.policy case final prompt?) {
        expect(prompt.canUseRemoteSigned, isTrue);
      }
    },
    skip: !File(legacy).existsSync(),
  );

  test('Windows PowerShell can skip the profile for just one launch', () async {
    ClaudeEnvironment.use({'SystemRoot': base['SystemRoot']!});
    final dir = Directory.systemTemp.createTempSync('baocode-powershell');
    addTearDown(() => dir.deleteSync());
    final launch = await terminalLaunch(dir.path, shellIntegration: false);
    expect(launch.executable, legacy);
    expect(launch.arguments, isEmpty);
    final skipped = await launchWindowsProfileChoice(
      launch,
      useRemoteSigned: false,
    );
    expect(skipped.arguments, ['-NoProfile']);
    expect(skipped.environment, same(launch.environment));
    expect(skipped.workingDirectory, dir.path);
    final profile = (await terminalProfiles()).profiles.singleWhere(
      (profile) => profile.name == 'Windows PowerShell',
    );
    expect(profile.args, launch.arguments);
    final result = await Process.run(skipped.executable, [
      ...skipped.arguments,
      '-Command',
      r'(Get-Location).Path',
    ], workingDirectory: launch.workingDirectory);
    expect(result.exitCode, 0);
    expect(result.stdout.toString().trim(), dir.path);
    expect(result.stderr, isEmpty);
    final oneTime = await launchWindowsProfileChoice(
      launch,
      useRemoteSigned: true,
    );
    expect(oneTime.arguments.take(2), ['-ExecutionPolicy', 'RemoteSigned']);
    expect(oneTime.workingDirectory, dir.path);
    expect(launch.arguments, isEmpty);
  }, skip: !File(legacy).existsSync());
}
