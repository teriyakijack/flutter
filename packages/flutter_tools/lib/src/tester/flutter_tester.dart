// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../application_package.dart';
import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/process_manager.dart';
import '../build_info.dart';
import '../bundle.dart' as bundle;
import '../dart/package_map.dart';
import '../device.dart';
import '../globals.dart';
import '../protocol_discovery.dart';
import '../version.dart';

class FlutterTesterApp extends ApplicationPackage {
  final String _directory;

  factory FlutterTesterApp.fromCurrentDirectory() {
    return new FlutterTesterApp._(fs.currentDirectory.path);
  }

  FlutterTesterApp._(String directory)
      : _directory = directory,
        super(id: directory);

  @override
  String get name => fs.path.basename(_directory);

  @override
  String get packagePath => fs.path.join(_directory, '.packages');
}

// TODO(scheglov): This device does not currently work with full restarts.
class FlutterTesterDevice extends Device {
  FlutterTesterDevice(String deviceId) : super(deviceId);

  Process _process;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  String get name => 'Flutter test device';

  @override
  DevicePortForwarder get portForwarder => null;

  @override
  Future<String> get sdkNameAndVersion async {
    final FlutterVersion flutterVersion = FlutterVersion.instance;
    return 'Flutter ${flutterVersion.frameworkRevisionShort}';
  }

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.tester;

  @override
  void clearLogs() {}

  final _FlutterTesterDeviceLogReader _logReader =
      new _FlutterTesterDeviceLogReader();

  @override
  DeviceLogReader getLogReader({ApplicationPackage app}) => _logReader;

  @override
  Future<bool> installApp(ApplicationPackage app) async => true;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app) async => false;

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => false;

  @override
  bool isSupported() => true;

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  @override
  Future<LaunchResult> startApp(
    ApplicationPackage package, {
    @required String mainPath,
    String route,
    @required DebuggingOptions debuggingOptions,
    Map<String, dynamic> platformArgs,
    bool prebuiltApplication = false,
    bool applicationNeedsRebuild = false,
    bool usesTerminalUi = true,
    bool ipv6 = false,
  }) async {
    final BuildInfo buildInfo = debuggingOptions.buildInfo;

    if (!buildInfo.isDebug) {
      printError('This device only supports debug mode.');
      return new LaunchResult.failed();
    }

    final String shellPath = artifacts.getArtifactPath(Artifact.flutterTester);
    if (!fs.isFileSync(shellPath))
      throwToolExit('Cannot find Flutter shell at $shellPath');

    final List<String> command = <String>[
      shellPath,
      '--run-forever',
      '--non-interactive',
      '--enable-dart-profiling',
      '--packages=${PackageMap.globalPackagesPath}',
    ];
    if (debuggingOptions.debuggingEnabled) {
      if (debuggingOptions.startPaused)
        command.add('--start-paused');
      if (debuggingOptions.hasObservatoryPort)
        command.add('--observatory-port=${debuggingOptions.observatoryPort}');
    }

    // Build assets and perform initial compilation.
    final String assetDirPath = getAssetBuildDirectory();
    final String applicationKernelFilePath = bundle.defaultApplicationKernelPath;
    await bundle.build(
      mainPath: mainPath,
      assetDirPath: assetDirPath,
      applicationKernelFilePath: applicationKernelFilePath,
      precompiledSnapshot: !buildInfo.previewDart2,
      previewDart2: buildInfo.previewDart2,
      trackWidgetCreation: buildInfo.trackWidgetCreation,
    );
    if (buildInfo.previewDart2) {
      mainPath = applicationKernelFilePath;
    }

    command.add('--flutter-assets-dir=$assetDirPath');

    // TODO(scheglov): Either remove the check, or make it fail earlier.
    if (mainPath != null) {
      command.add(mainPath);
    }

    try {
      printTrace(command.join(' '));

      _isRunning = true;
      _process = await processManager.start(command,
      environment: <String, String>{
        'FLUTTER_TEST': 'true',
      });
      _process.exitCode.then((_) => _isRunning = false);
      _process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) {
        _logReader.addLine(line);
      });
      _process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) {
        _logReader.addLine(line);
      });

      if (!debuggingOptions.debuggingEnabled)
        return new LaunchResult.succeeded();

      final ProtocolDiscovery observatoryDiscovery = new ProtocolDiscovery.observatory(
        getLogReader(),
        hostPort: debuggingOptions.observatoryPort,
      );

      final Uri observatoryUri = await observatoryDiscovery.uri;
      return new LaunchResult.succeeded(observatoryUri: observatoryUri);
    } catch (error) {
      printError('Failed to launch $package: $error');
      return new LaunchResult.failed();
    }
  }

  @override
  Future<bool> stopApp(ApplicationPackage app) async {
    _process?.kill();
    _process = null;
    return true;
  }

  @override
  Future<bool> uninstallApp(ApplicationPackage app) async => true;
}

class FlutterTesterDevices extends PollingDeviceDiscovery {
  FlutterTesterDevices() : super('Flutter tester');

  static const String kTesterDeviceId = 'flutter-tester';

  static bool showFlutterTesterDevice = false;

  final FlutterTesterDevice _testerDevice =
      new FlutterTesterDevice(kTesterDeviceId);

  @override
  bool get canListAnything => true;

  @override
  bool get supportsPlatform => true;

  @override
  Future<List<Device>> pollingGetDevices() async {
    return showFlutterTesterDevice ? <Device>[_testerDevice] : <Device>[];
  }
}

class _FlutterTesterDeviceLogReader extends DeviceLogReader {
  final StreamController<String> _logLinesController =
      new StreamController<String>.broadcast();

  @override
  int get appPid => 0;

  @override
  Stream<String> get logLines => _logLinesController.stream;

  @override
  String get name => 'flutter tester log reader';

  void addLine(String line) => _logLinesController.add(line);
}
