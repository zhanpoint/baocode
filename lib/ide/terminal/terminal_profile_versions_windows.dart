import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'terminal_profiles.dart';

/// Enrich local Windows profiles from one read-only query. A failure leaves
/// discovery and shell selection unchanged. The profile service caches this
/// result along with the rest of discovery.
Future<List<TerminalProfile>> withWindowsTerminalProfileVersions(
  List<TerminalProfile> profiles,
) async {
  if (!Platform.isWindows || profiles.isEmpty) return profiles;
  try {
    final executable = systemWindowsPowerShellExecutable();
    if (executable == null) return profiles;
    final local = Platform.environment['LOCALAPPDATA'];
    final aliases = local == null || !p.windows.isAbsolute(local)
        ? null
        : p.windows.join(local, 'Microsoft', 'WindowsApps');
    final paths = <String, Map<String, String>>{};
    for (final profile in profiles) {
      final path = p.windows.normalize(profile.path);
      final key = path.toLowerCase();
      if (!p.windows.isAbsolute(path) || paths.containsKey(key)) continue;
      if (key == executable.toLowerCase()) {
        paths[key] = {'kind': 'legacy'};
      } else if (p.windows.basename(key) == 'pwsh.exe') {
        if (aliases != null && p.windows.isWithin(aliases.toLowerCase(), key)) {
          final parent = p.windows.dirname(key);
          final folder = p.windows.basename(parent);
          if (parent != aliases.toLowerCase() &&
              !(p.windows.dirname(parent) == aliases.toLowerCase() &&
                  _storeFamilies.contains(folder))) {
            continue;
          }
          final fullName = _aliasPackageFullName(path);
          if (fullName != null) {
            paths[key] = {'kind': 'store', 'package': fullName};
          }
        } else {
          paths[key] = {'kind': 'file', 'path': path};
        }
      }
    }
    if (paths.isEmpty) return profiles;
    final versions = await _query(executable, paths.values.toList());
    if (versions == null || versions.length != paths.length) return profiles;
    final byPath = Map.fromIterables(paths.keys, versions);
    return [
      for (final profile in profiles)
        if (byPath[p.windows.normalize(profile.path).toLowerCase()]
            case final String version when _versionPattern.hasMatch(version))
          profile.withVersion(version)
        else
          profile,
    ];
  } on Exception {
    return profiles;
  }
}

final _versionPattern = RegExp(r'^\d+\.\d+(?:\.\d+){0,2}(?:-[\w.-]+)?$');

Future<List<Object?>?> _query(
  String executable,
  List<Map<String, String>> requests,
) async {
  final process = await Process.start(executable, [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    _script,
  ], workingDirectory: p.windows.dirname(executable));
  try {
    // Pass paths as UTF-8 data, not as parts of the command. Base64 keeps the
    // stdin transport independent of the installed Windows code page.
    final results = await Future.wait<Object?>([
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.drain<void>(),
      process.exitCode,
      Future<void>(() async {
        process.stdin.writeln(base64.encode(utf8.encode(jsonEncode(requests))));
        await process.stdin.close();
      }),
    ], eagerError: true).timeout(const Duration(seconds: 4));
    if (results[2] != 0) return null;
    final value = jsonDecode(results[0]! as String);
    return value is List<Object?> ? value : null;
  } on TimeoutException {
    process.kill();
    return null;
  } on Exception {
    process.kill();
    return null;
  }
}

const _script = r'''
$ErrorActionPreference = 'Stop'
$env:PSModulePath = "$PSHOME\Modules"
$requests = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::ReadLine())) | ConvertFrom-Json
$packages = @{}
if ($requests.kind -contains 'store') {
  try {
    foreach ($package in (Appx\Get-AppxPackage -Name 'Microsoft.PowerShell*')) {
      $packages[$package.PackageFullName] = $package.Version.ToString()
    }
  } catch {}
}
$versions = @(foreach ($request in $requests) {
  $version = $null
  try {
    switch ($request.kind) {
      'legacy' {
        $version = '{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor
      }
      'store' {
        $version = $packages[$request.package]
        if ($version -match '^(\d+\.\d+\.\d+)\.0$') { $version = $Matches[1] }
      }
      'file' {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($request.path)
        if ($info.ProductVersion -match '^(\d+\.\d+\.\d+(?:\.\d+)?(?:-[\w.-]+)?)(?:\s|\+|$)') {
          $version = $Matches[1]
        }
      }
    }
  } catch {}
  $version
})
[Console]::WriteLine((ConvertTo-Json -InputObject $versions -Compress))
''';

const _storeFamilies = {
  'microsoft.powershell_8wekyb3d8bbwe',
  'microsoft.powershellpreview_8wekyb3d8bbwe',
};

final _storeFullName = RegExp(
  r'^Microsoft\.PowerShell(?:Preview)?_\d+\.\d+\.\d+\.\d+_[a-z0-9]+__8wekyb3d8bbwe$',
  caseSensitive: false,
);

/// Read the Windows AppExecLink reparse data, without resolving the alias
/// through process creation. The shared pwsh.exe alias might select Preview
/// even when the stable package is installed, so do not guess from its name.
String? _aliasPackageFullName(String path) {
  const capacity = 16 * 1024; // MAXIMUM_REPARSE_DATA_BUFFER_SIZE
  final pathMemory = _allocate((path.length + 1) * 2);
  final data = _allocate(capacity + 4);
  try {
    if (pathMemory == nullptr || data == nullptr) return null;
    pathMemory
        .cast<Uint16>()
        .asTypedList(path.length)
        .setAll(0, path.codeUnits);
    // Open the reparse point itself, with no access to the target file.
    final file = _createFile(
      pathMemory.cast(),
      0,
      7,
      nullptr,
      3,
      0x00200000,
      0,
    );
    if (file == -1) return null;
    try {
      final written = (data + capacity).cast<Uint32>();
      const getReparsePoint = 0x000900a8; // FSCTL_GET_REPARSE_POINT
      if (_deviceIoControl(
                file,
                getReparsePoint,
                nullptr,
                0,
                data,
                capacity,
                written,
                nullptr,
              ) ==
              0 ||
          written.value < 12 ||
          data.cast<Uint32>().value != 0x8000001b ||
          data.cast<Uint32>()[2] != 3) {
        return null;
      }
      final length = data.cast<Uint16>()[2];
      if (length < 4 || length + 8 > written.value || length.isOdd) return null;
      final units = (data + 12).cast<Uint16>().asTypedList((length - 4) ~/ 2);
      final strings = String.fromCharCodes(units).split('\u0000');
      if (strings.length < 4 ||
          !_storeFamilies.contains(strings[0].toLowerCase())) {
        return null;
      }
      final target = strings[2];
      final package = p.windows.basename(p.windows.dirname(target));
      return p.windows.basename(target).toLowerCase() == 'pwsh.exe' &&
              _storeFullName.hasMatch(package)
          ? package
          : null;
    } finally {
      _closeHandle(file);
    }
  } finally {
    _free(pathMemory);
    _free(data);
  }
}

/// The system PowerShell path, independent of PATH and user settings.
String? systemWindowsPowerShellExecutable() {
  if (!Platform.isWindows) return null;
  final root = _systemWindowsDirectory();
  if (root == null) return null;
  return p.windows.join(
    root,
    r'System32\WindowsPowerShell\v1.0\powershell.exe',
  );
}

String? _systemWindowsDirectory() {
  const capacity = 260;
  final data = _allocate(capacity * 2);
  if (data == nullptr) return null;
  try {
    final path = data.cast<Uint16>();
    final length = _getWindowsDirectory(path, capacity);
    if (length == 0 || length >= capacity) return null;
    return String.fromCharCodes(path.asTypedList(length));
  } finally {
    _free(data);
  }
}

final _kernel = DynamicLibrary.open('kernel32.dll');
final _getWindowsDirectory = _kernel
    .lookupFunction<
      Uint32 Function(Pointer<Uint16>, Uint32),
      int Function(Pointer<Uint16>, int)
    >('GetSystemWindowsDirectoryW');
final _processHeap = _kernel.lookupFunction<IntPtr Function(), int Function()>(
  'GetProcessHeap',
)();
final _heapAlloc = _kernel
    .lookupFunction<
      Pointer<Uint8> Function(IntPtr, Uint32, UintPtr),
      Pointer<Uint8> Function(int, int, int)
    >('HeapAlloc');
final _heapFree = _kernel
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Uint8>),
      int Function(int, int, Pointer<Uint8>)
    >('HeapFree');
final _createFile = _kernel
    .lookupFunction<
      IntPtr Function(
        Pointer<Uint16>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        IntPtr,
      ),
      int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int)
    >('CreateFileW');
final _deviceIoControl = _kernel
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Uint32,
        Pointer<Void>,
        Uint32,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(
        int,
        int,
        Pointer<Void>,
        int,
        Pointer<Uint8>,
        int,
        Pointer<Uint32>,
        Pointer<Void>,
      )
    >('DeviceIoControl');
final _closeHandle = _kernel
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

Pointer<Uint8> _allocate(int bytes) => _heapAlloc(_processHeap, 8, bytes);

void _free(Pointer<Uint8> address) {
  if (address != nullptr) _heapFree(_processHeap, 0, address);
}
