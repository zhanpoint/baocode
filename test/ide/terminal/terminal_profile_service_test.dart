import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_quick_input.dart';
import 'package:baocode/ide/terminal/terminal_instance.dart';
import 'package:baocode/ide/terminal/terminal_profile_service.dart';
import 'package:baocode/ide/terminal/terminal_profiles.dart';
import 'package:baocode/ide/terminal/terminal_service.dart';
import 'package:baocode/ide/terminal/terminal_shell.dart';
import 'package:baocode/l10n/app_localizations_en.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:path/path.dart' as p;

import 'fake_pty.dart';
import 'fake_terminal.dart';

void main() {
  late Directory temp;
  late UserSettings settings;
  late List<FakePty> started;
  late List<Object?> detections;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baocode-terminal-profiles');
    settings = UserSettings(
      p.join(temp.path, 'User', 'settings.json'),
      debounce: Duration.zero,
    );
    started = [];
    detections = [];
  });

  tearDown(() async {
    settings.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> write(String text) async {
    await File(settings.path).parent.create(recursive: true);
    await File(settings.path).writeAsString(text);
    await settings.load();
  }

  TerminalBackend backend({UserSettings? userSettings}) => TerminalBackend(
    launch: fakeTerminalLaunch,
    start: FakePty.starter(started),
    detectProfiles: ({Object? configured}) {
      detections.add(configured);
      return fakeTerminalProfiles(configured: configured);
    },
    settings: userSettings,
  );

  TerminalProfileService service({UserSettings? userSettings}) =>
      TerminalProfileService(
        backend(userSettings: userSettings),
        os: TerminalOs.macOS,
      );

  test('detects the profiles when first asked, once', () async {
    final profiles = service(userSettings: settings);
    addTearDown(profiles.dispose);
    expect(profiles.availableProfiles, isEmpty);
    expect(detections, isEmpty);

    await Future.wait([profiles.refresh(), profiles.refresh()]);
    await profiles.refresh();
    expect(detections, hasLength(1));
    expect(profiles.availableProfiles.map((profile) => profile.name), [
      'bash',
      'sh',
      'zsh',
      'fish',
    ]);
    // None set: the user's shell's.
    expect(profiles.defaultProfileSetting, isNull);
    expect(profiles.defaultProfileName, 'zsh');
  });

  test("detects them again after the user's profiles change, with them, "
      'not after another setting does', () async {
    await write('{}');
    final profiles = service(userSettings: settings);
    addTearDown(profiles.dispose);
    await profiles.refresh();

    await write('{"editor.fontSize": 14}');
    await profiles.refresh();
    expect(detections, hasLength(1));

    await write('''{
      // mine
      "terminal.integrated.profiles.osx": {
        "sh": null,
        "Login fish": { "path": "fish", "args": ["--login"] },
      },
    }''');
    await profiles.refresh();
    expect(detections, hasLength(2));
    expect(detections.last, isA<Map<String, Object?>>());
    expect(profiles.availableProfiles.map((profile) => profile.name), [
      'bash',
      'zsh',
      'fish',
      'Login fish',
    ]);
    expect(
      profiles.profileNamed('Login fish'),
      const TerminalProfile(
        name: 'Login fish',
        path: '/opt/homebrew/bin/fish',
        args: ['--login'],
        isUserConfigured: true,
      ),
    );
  });

  test('Select Default Profile writes it to settings.json; new terminals '
      'start it', () async {
    await write('{\n  // mine\n  "editor.fontSize": 14\n}\n');
    // The service's system is the app's.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final terminals = TerminalService(
      root: '/project',
      backend: backend(userSettings: settings),
    );
    addTearDown(terminals.dispose);
    final profiles = terminals.profiles;
    expect(profiles.canSetDefault, isTrue);
    // None set: the user's shell, not waiting for the profiles.
    expect(profiles.defaultShell(), isNull);

    await profiles.refresh();
    var changes = 0;
    profiles.addListener(() => changes++);
    await profiles.setDefaultProfile(profiles.profileNamed('bash')!);
    expect(changes, greaterThan(0));
    expect(settings['terminal.integrated.defaultProfile.osx'], 'bash');
    final text = await File(settings.path).readAsString();
    expect(text, contains('// mine'));
    expect(text, contains('"terminal.integrated.defaultProfile.osx": "bash"'));
    expect(profiles.defaultProfileName, 'bash');

    terminals.create();
    await pumpEventQueue();
    expect(started.last.launch!.executable, '/bin/bash');
    expect(started.last.launch!.arguments, ['-l']);

    // A profile given starts that one.
    terminals.create(profile: profiles.profileNamed('fish'));
    await pumpEventQueue();
    expect(started.last.launch!.executable, '/opt/homebrew/bin/fish');

    // A default that is not there: the user's shell.
    await settings.update('terminal.integrated.defaultProfile.osx', 'nu');
    expect(profiles.defaultProfileName, 'zsh');
    terminals.create();
    await pumpEventQueue();
    expect(started.last.launch!.executable, '/bin/zsh');
  });

  test(
    'version labels do not change which profile is saved or selected',
    () async {
      const modern = TerminalProfile(
        name: 'PowerShell',
        path: r'C:\Program Files\PowerShell\7\pwsh.exe',
        version: '7.7.0',
      );
      const legacy = TerminalProfile(
        name: 'Windows PowerShell',
        path: r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        version: '5.1',
        isAutoDetected: true,
      );
      final profiles = TerminalProfileService(
        TerminalBackend(
          launch: fakeTerminalLaunch,
          start: FakePty.starter(started),
          detectProfiles: ({Object? configured}) async =>
              (profiles: [modern, legacy], systemShell: modern.shell),
          settings: settings,
        ),
        os: TerminalOs.windows,
      );
      addTearDown(profiles.dispose);
      await profiles.refresh();
      await profiles.setDefaultProfile(legacy);
      expect(
        settings['terminal.integrated.defaultProfile.windows'],
        legacy.name,
      );
      expect(profiles.defaultProfileName, legacy.name);
      expect(await profiles.defaultShell(), legacy.shell);

      TerminalProfile? picked;
      final pick = terminalProfilePick(
        profiles: profiles.availableProfiles,
        defaultName: profiles.defaultProfileName,
        placeholder: 'Pick one',
        onPick: (profile) => picked = profile,
        l10n: AppLocalizationsEn(),
      );
      expect(
        pick.items.whereType<IdeQuickPickItem>().map((item) => item.label),
        ['PowerShell（7.7.0）', 'PowerShell（5.1）'],
      );
      final active = pick.activeItems!.single;
      expect(active.label, 'PowerShell（5.1）');
      pick.onDidAccept!(active);
      expect(picked, legacy);
    },
  );

  test('without settings.json no default can be set', () async {
    final profiles = service();
    addTearDown(profiles.dispose);
    expect(profiles.canSetDefault, isFalse);
    expect(profiles.defaultShell(), isNull);
    await profiles.refresh();
    expect(profiles.defaultProfileName, 'zsh');
  });

  test('a detection that fails leaves no profiles', () async {
    final profiles = TerminalProfileService(
      TerminalBackend(
        launch: fakeTerminalLaunch,
        start: FakePty.starter(started),
        detectProfiles: ({Object? configured}) async =>
            throw const FileSystemException('no /etc/shells'),
      ),
      os: TerminalOs.macOS,
    );
    addTearDown(profiles.dispose);
    await profiles.refresh();
    expect(profiles.availableProfiles, isEmpty);
    expect(profiles.defaultProfileName, isNull);
  });

  test("the dropdown's profiles: those of the settings, the default first, "
      'the others by name', () async {
    final found = (await fakeTerminalProfiles()).profiles;
    expect(
      terminalDropdownProfiles(found, 'zsh').map((profile) => profile.name),
      ['zsh', 'bash', 'fish'],
    );
    expect(
      terminalDropdownProfiles(found, 'sh').map((profile) => profile.name),
      ['bash', 'fish', 'zsh'],
    );
    expect(
      terminalDropdownProfiles(
        found,
        'sh',
        includeDetected: true,
      ).map((profile) => profile.name),
      ['sh', 'bash', 'fish', 'zsh'],
    );
  });

  test('the quick pick: those of the settings, then those detected, each '
      "with its shell's command line; the default active", () async {
    final found = (await fakeTerminalProfiles(
      configured: {
        'Spaced': {
          'path': '/bin/zsh',
          'args': ['-c', 'echo "hi there"'],
        },
      },
    )).profiles;
    TerminalProfile? picked;
    final pick = terminalProfilePick(
      profiles: found,
      defaultName: 'zsh',
      placeholder: 'Pick one',
      onPick: (profile) => picked = profile,
      l10n: AppLocalizationsEn(),
    );
    expect(pick.placeholder, 'Pick one');
    expect(
      [
        for (final entry in pick.items)
          switch (entry) {
            IdeQuickPickSeparator(:final label) => '-- $label',
            IdeQuickPickItem(:final label, :final description) =>
              '$label: $description',
          },
      ],
      [
        '-- profiles',
        'bash: /bin/bash -l',
        'zsh: /bin/zsh -l',
        'fish: /opt/homebrew/bin/fish -l',
        r'Spaced: /bin/zsh -c "echo \"hi there\""',
        '-- detected',
        'sh: /bin/sh',
      ],
    );
    final zsh = pick.activeItems!.single;
    expect(zsh.label, 'zsh');
    pick.onDidAccept!(zsh);
    expect(picked?.name, 'zsh');
  });
}
