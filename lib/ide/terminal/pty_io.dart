import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show windowsAppExecutionAliasExists;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../kernel/claude_code/claude_environment.dart';
import '../../platform/data_dir.dart';
import '../../platform/child_process_registry.dart';
import 'pty.dart';
import 'shell_integration/shell_integration_files.dart';
import 'terminal_profile_versions_windows.dart';
import 'terminal_profiles.dart';
import 'terminal_shell.dart';

abstract final class PtyProcesses {
  /// Where the running terminal processes are kept track of across runs. A
  /// leftover is hung up, as closing its terminal would have.
  @visibleForTesting
  static ChildProcessRegistry registry = ChildProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('pty')),
    signal: (pid) => Process.killPid(pid, ProcessSignal.sighup),
  );

  static final Set<Pty> _live = {};

  static Future<Pty> start(PtyLaunch launch) async {
    await registry.reaped;
    final pty = await spawnPty(launch);
    _live.add(pty);
    unawaited(registry.add(pty.pid));
    unawaited(
      pty.exitCode.then((_) {
        _live.remove(pty);
        unawaited(registry.remove(pty.pid));
      }),
    );
    return pty;
  }

  static TerminalOs get _os => Platform.isWindows
      ? TerminalOs.windows
      : Platform.isMacOS
      ? TerminalOs.macOS
      : TerminalOs.linux;

  static bool _exists(String path) =>
      File(path).existsSync() || windowsAppExecutionAliasExists(path);

  static List<String> _list(String directory) {
    try {
      return [
        for (final entity in Directory(directory).listSync())
          p.basename(entity.path),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  /// Whether [shell] is started as a login shell known to read the login
  /// files. Other arguments, or a shell it does not know, are not guessed
  /// at.
  static bool _readsLoginFiles(TerminalShell shell) {
    if (!const {'bash', 'zsh', 'fish'}.contains(p.basename(shell.executable))) {
      return false;
    }
    final args = shell.arguments
        .where((arg) => arg != '-i' && arg != '--interactive')
        .toList();
    return args.length == 1 &&
        const {'-l', '--login', '-il', '-li'}.contains(args.single);
  }

  static Future<PtyLaunch> terminalLaunch(
    String root, {
    required int columns,
    required int rows,
    required bool shellIntegration,
    TerminalShell? shell,
    TerminalEnvironmentRequest? environment,
  }) async {
    final os = _os;
    final resolved = await ClaudeEnvironment.of();
    shell ??= defaultTerminalShell(os, resolved, exists: _exists, list: _list);
    // As VS Code, whose terminals inherit the environment it resolved from
    // the login shell; but that one is of when the app started, and a login
    // shell reads the files as they are now (one changed since, #226).
    final base = os != TerminalOs.windows && _readsLoginFiles(shell)
        ? Platform.environment
        : resolved;
    final launch = PtyLaunch(
      executable: shell.executable,
      arguments: shell.arguments,
      workingDirectory: root,
      // VS Code adds the terminal's variables to a strict environment
      // too (`addTerminalEnvironmentKeys`).
      environment: _finish(
        environment,
        terminalEnvironment(
          environment?.merge(base) ?? base,
          os: os,
          locale: Platform.localeName,
        ),
      ),
      columns: columns,
      rows: rows,
    );
    return shellIntegration ? injectShellIntegration(launch, os: os) : launch;
  }

  static Future<({PtyLaunch launch, WindowsProfilePolicy? policy})>
  prepareInteractiveTerminalLaunch(
    String root, {
    required int columns,
    required int rows,
    TerminalShell? shell,
    TerminalEnvironmentRequest? environment,
  }) async {
    final launch = await terminalLaunch(
      root,
      columns: columns,
      rows: rows,
      shell: shell,
      environment: environment,
      shellIntegration: false,
    );
    final legacy =
        Platform.isWindows &&
            p.windows.basename(launch.executable).toLowerCase() ==
                'powershell.exe'
        ? systemWindowsPowerShellExecutable()
        : null;
    if (legacy != null &&
        p.windows.equals(launch.executable, legacy) &&
        launch.arguments.every(
          (arg) => const ['-nologo', '-nol'].contains(arg.toLowerCase()),
        )) {
      final restriction = await _windowsProfileRestriction(launch, legacy);
      if (restriction != null) {
        return (
          launch: launch,
          policy: restriction.hasProfile
              ? (canUseRemoteSigned: restriction.canUseRemoteSigned)
              : null,
        );
      }
    }
    return (launch: injectShellIntegration(launch, os: _os), policy: null);
  }

  static Future<({bool hasProfile, bool canUseRemoteSigned})?>
  _windowsProfileRestriction(PtyLaunch launch, String executable) async {
    final shellHome = p.windows.dirname(executable);
    try {
      final probe = await Process.start(
        executable,
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'''
$ErrorActionPreference = 'Stop'
$effective = Microsoft.PowerShell.Security\Get-ExecutionPolicy
if ($effective -ne 'Restricted') { exit }
$scopes = Microsoft.PowerShell.Security\Get-ExecutionPolicy -List
$group = @($scopes | Where-Object {
  $_.Scope -in 'MachinePolicy','UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined'
}).Count -gt 0
$profileExists = $false
foreach ($file in @($PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost,
                    $PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
  if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $file -PathType Leaf) {
    $profileExists = $true
    break
  }
}
@{hasProfile=$profileExists; canUseRemoteSigned=(-not $group)} |
  Microsoft.PowerShell.Utility\ConvertTo-Json -Compress
''',
        ],
        workingDirectory: shellHome,
        environment: {
          for (final entry in launch.environment!.entries)
            if (entry.key.toUpperCase() != 'PSMODULEPATH')
              entry.key: entry.value,
          'PSModulePath': p.windows.join(shellHome, 'Modules'),
        },
        includeParentEnvironment: false,
      );
      final output =
          await Future.wait<Object?>([
            ascii.decoder.bind(probe.stdout).join(),
            probe.stderr.drain<Object?>(),
            probe.exitCode,
          ]).timeout(
            const Duration(seconds: 4),
            onTimeout: () {
              probe.kill();
              throw TimeoutException('Windows PowerShell profile check');
            },
          );
      if (output[2] != 0 || (output[0] as String).trim().isEmpty) return null;
      final json = jsonDecode(output[0] as String);
      if (json case {
        'hasProfile': final bool exists,
        'canUseRemoteSigned': final bool canUseRemoteSigned,
      }) {
        return (hasProfile: exists, canUseRemoteSigned: canUseRemoteSigned);
      }
    } on ProcessException {
      return null;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    }
    return null;
  }

  static Future<PtyLaunch> launchWindowsProfileChoice(
    PtyLaunch launch, {
    required bool useRemoteSigned,
  }) async {
    if (useRemoteSigned) launch = injectShellIntegration(launch, os: _os);
    return PtyLaunch(
      executable: launch.executable,
      arguments: [
        if (useRemoteSigned) ...[
          '-ExecutionPolicy',
          'RemoteSigned',
        ] else
          '-NoProfile',
        ...launch.arguments,
      ],
      workingDirectory: launch.workingDirectory,
      environment: launch.environment,
      columns: launch.columns,
      rows: launch.rows,
    );
  }

  static Map<String, String> _finish(
    TerminalEnvironmentRequest? request,
    Map<String, String> environment,
  ) => request?.finish(environment) ?? environment;

  static Future<TerminalProfiles> terminalProfiles({Object? configured}) async {
    final os = _os;
    final base = await ClaudeEnvironment.of();
    String? shells;
    if (os != TerminalOs.windows) {
      try {
        shells = await File('/etc/shells').readAsString();
      } on FileSystemException {
        shells = null;
      }
    }
    final profiles = detectTerminalProfiles(
      os,
      base,
      exists: _exists,
      list: _list,
      etcShells: shells,
      configured: configured,
    );
    return (
      profiles: os == TerminalOs.windows
          ? await withWindowsTerminalProfileVersions(profiles)
          : profiles,
      systemShell: defaultTerminalShell(os, base, exists: _exists, list: _list),
    );
  }

  /// Hangs up every terminal this run started, and waits (up to [timeout]
  /// each) for its process to end: killed if it does not.
  static Future<void> stopAll({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    await Future.wait([
      for (final pty in [..._live]) _stop(pty, timeout),
    ]);
    // Their entries gone from the list before the app is.
    await registry.flush();
  }

  static Future<void> _stop(Pty pty, Duration timeout) async {
    pty.kill();
    try {
      await pty.exitCode.timeout(timeout);
    } on TimeoutException {
      pty.kill(PtySignal.kill);
      await pty.exitCode.timeout(timeout, onTimeout: () => 0);
    }
  }

  static Future<void> reapLeftovers() => registry.reaped;
}
