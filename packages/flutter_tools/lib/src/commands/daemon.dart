// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import '../android/android_device.dart';
import '../base/common.dart';
import '../base/context.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../cache.dart';
import '../device.dart';
import '../globals.dart';
import '../ios/devices.dart';
import '../ios/simulators.dart';
import '../resident_runner.dart';
import '../run_cold.dart';
import '../run_hot.dart';
import '../runner/flutter_command.dart';
import '../vmservice.dart';

const String protocolVersion = '0.2.0';

/// A server process command. This command will start up a long-lived server.
/// It reads JSON-RPC based commands from stdin, executes them, and returns
/// JSON-RPC based responses and events to stdout.
///
/// It can be shutdown with a `daemon.shutdown` command (or by killing the
/// process).
class DaemonCommand extends FlutterCommand {
  DaemonCommand({ this.hidden: false });

  @override
  final String name = 'daemon';

  @override
  final String description = 'Run a persistent, JSON-RPC based server to communicate with devices.';

  @override
  final bool hidden;

  @override
  Future<Null> runCommand() {
    printStatus('Starting device daemon...');

    final AppContext appContext = new AppContext();
    final NotifyingLogger notifyingLogger = new NotifyingLogger();
    appContext.setVariable(Logger, notifyingLogger);

    Cache.releaseLockEarly();

    return appContext.runInZone(() async {
      final Daemon daemon = new Daemon(
          stdinCommandStream, stdoutCommandResponse,
          daemonCommand: this, notifyingLogger: notifyingLogger);

      final int code = await daemon.onExit;
      if (code != 0)
        throwToolExit('Daemon exited with non-zero exit code: $code', exitCode: code);
    }, onError: _handleError);
  }

  dynamic _handleError(dynamic error, StackTrace stackTrace) {
    printError('Error from flutter daemon: $error', stackTrace);
    return null;
  }
}

typedef void DispatchCommand(Map<String, dynamic> command);

typedef Future<dynamic> CommandHandler(Map<String, dynamic> args);

class Daemon {
  Daemon(Stream<Map<String, dynamic>> commandStream, this.sendCommand, {
    this.daemonCommand,
    this.notifyingLogger,
    this.logToStdout: false
  }) {
    // Set up domains.
    _registerDomain(daemonDomain = new DaemonDomain(this));
    _registerDomain(appDomain = new AppDomain(this));
    _registerDomain(deviceDomain = new DeviceDomain(this));

    // Start listening.
    commandStream.listen(
      _handleRequest,
      onDone: () {
        if (!_onExitCompleter.isCompleted)
            _onExitCompleter.complete(0);
      }
    );
  }

  DaemonDomain daemonDomain;
  AppDomain appDomain;
  DeviceDomain deviceDomain;

  final DispatchCommand sendCommand;
  final DaemonCommand daemonCommand;
  final NotifyingLogger notifyingLogger;
  final bool logToStdout;

  final Completer<int> _onExitCompleter = new Completer<int>();
  final Map<String, Domain> _domainMap = <String, Domain>{};

  void _registerDomain(Domain domain) {
    _domainMap[domain.name] = domain;
  }

  Future<int> get onExit => _onExitCompleter.future;

  void _handleRequest(Map<String, dynamic> request) {
    // {id, method, params}

    // [id] is an opaque type to us.
    final dynamic id = request['id'];

    if (id == null) {
      stderr.writeln('no id for request: $request');
      return;
    }

    try {
      final String method = request['method'];
      if (!method.contains('.'))
        throw 'method not understood: $method';

      final String prefix = method.substring(0, method.indexOf('.'));
      final String name = method.substring(method.indexOf('.') + 1);
      if (_domainMap[prefix] == null)
        throw 'no domain for method: $method';

      _domainMap[prefix].handleCommand(name, id, request['params'] ?? const <String, dynamic>{});
    } catch (error) {
      _send(<String, dynamic>{'id': id, 'error': _toJsonable(error)});
    }
  }

  void _send(Map<String, dynamic> map) => sendCommand(map);

  void shutdown() {
    _domainMap.values.forEach((Domain domain) => domain.dispose());
    if (!_onExitCompleter.isCompleted)
      _onExitCompleter.complete(0);
  }
}

abstract class Domain {
  Domain(this.daemon, this.name);

  final Daemon daemon;
  final String name;
  final Map<String, CommandHandler> _handlers = <String, CommandHandler>{};

  void registerHandler(String name, CommandHandler handler) {
    _handlers[name] = handler;
  }

  FlutterCommand get command => daemon.daemonCommand;

  @override
  String toString() => name;

  void handleCommand(String command, dynamic id, Map<String, dynamic> args) {
    new Future<dynamic>.sync(() {
      if (_handlers.containsKey(command))
        return _handlers[command](args);
      throw 'command not understood: $name.$command';
    }).then<Null>((dynamic result) {
      if (result == null) {
        _send(<String, dynamic>{'id': id});
      } else {
        _send(<String, dynamic>{'id': id, 'result': _toJsonable(result)});
      }
    }).catchError((dynamic error, dynamic trace) {
      _send(<String, dynamic>{'id': id, 'error': _toJsonable(error)});
    });
  }

  void sendEvent(String name, [dynamic args]) {
    final Map<String, dynamic> map = <String, dynamic>{ 'event': name };
    if (args != null)
      map['params'] = _toJsonable(args);
    _send(map);
  }

  void _send(Map<String, dynamic> map) => daemon._send(map);

  String _getStringArg(Map<String, dynamic> args, String name, { bool required: false }) {
    if (required && !args.containsKey(name))
      throw "$name is required";
    final dynamic val = args[name];
    if (val != null && val is! String)
      throw "$name is not a String";
    return val;
  }

  bool _getBoolArg(Map<String, dynamic> args, String name, { bool required: false }) {
    if (required && !args.containsKey(name))
      throw "$name is required";
    final dynamic val = args[name];
    if (val != null && val is! bool)
      throw "$name is not a bool";
    return val;
  }

  int _getIntArg(Map<String, dynamic> args, String name, { bool required: false }) {
    if (required && !args.containsKey(name))
      throw "$name is required";
    final dynamic val = args[name];
    if (val != null && val is! int)
      throw "$name is not an int";
    return val;
  }

  void dispose() { }
}

/// This domain responds to methods like [version] and [shutdown].
///
/// This domain fires the `daemon.logMessage` event.
class DaemonDomain extends Domain {
  DaemonDomain(Daemon daemon) : super(daemon, 'daemon') {
    registerHandler('version', version);
    registerHandler('shutdown', shutdown);

    _subscription = daemon.notifyingLogger.onMessage.listen((LogMessage message) {
      if (daemon.logToStdout) {
        if (message.level == 'status') {
          // We use `print()` here instead of `stdout.writeln()` in order to
          // capture the print output for testing.
          print(message.message);
        } else if (message.level == 'error') {
          stderr.writeln(message.message);
          if (message.stackTrace != null)
            stderr.writeln(message.stackTrace.toString().trimRight());
        }
      } else {
        if (message.stackTrace != null) {
          sendEvent('daemon.logMessage', <String, dynamic>{
            'level': message.level,
            'message': message.message,
            'stackTrace': message.stackTrace.toString()
          });
        } else {
          sendEvent('daemon.logMessage', <String, dynamic>{
            'level': message.level,
            'message': message.message
          });
        }
      }
    });
  }

  StreamSubscription<LogMessage> _subscription;

  Future<String> version(Map<String, dynamic> args) {
    return new Future<String>.value(protocolVersion);
  }

  Future<Null> shutdown(Map<String, dynamic> args) {
    Timer.run(daemon.shutdown);
    return new Future<Null>.value();
  }

  @override
  void dispose() {
    _subscription?.cancel();
  }
}

/// This domain responds to methods like [start] and [stop].
///
/// It fires events for application start, stop, and stdout and stderr.
class AppDomain extends Domain {
  AppDomain(Daemon daemon) : super(daemon, 'app') {
    registerHandler('start', start);
    registerHandler('restart', restart);
    registerHandler('callServiceExtension', callServiceExtension);
    registerHandler('stop', stop);
    registerHandler('discover', discover);
  }

  static final Uuid _uuidGenerator = new Uuid();

  static String _getNewAppId() => _uuidGenerator.generateV4();

  final List<AppInstance> _apps = <AppInstance>[];

  Future<Map<String, dynamic>> start(Map<String, dynamic> args) async {
    final String deviceId = _getStringArg(args, 'deviceId', required: true);
    final String projectDirectory = _getStringArg(args, 'projectDirectory', required: true);
    final bool startPaused = _getBoolArg(args, 'startPaused') ?? false;
    final bool useTestFonts = _getBoolArg(args, 'useTestFonts') ?? false;
    final String route = _getStringArg(args, 'route');
    final String mode = _getStringArg(args, 'mode');
    final String target = _getStringArg(args, 'target');
    final bool enableHotReload = _getBoolArg(args, 'hot') ?? kHotReloadDefault;

    final Device device = daemon.deviceDomain._getOrLocateDevice(deviceId);
    if (device == null)
      throw "device '$deviceId' not found";

    if (!fs.isDirectorySync(projectDirectory))
      throw "'$projectDirectory' does not exist";

    final BuildMode buildMode = getBuildModeForName(mode) ?? BuildMode.debug;
    DebuggingOptions options;
    if (buildMode == BuildMode.release) {
      options = new DebuggingOptions.disabled(buildMode);
    } else {
      options = new DebuggingOptions.enabled(
        buildMode,
        startPaused: startPaused,
        useTestFonts: useTestFonts,
      );
    }

    final AppInstance app = await startApp(
      device,
      projectDirectory,
      target,
      route,
      options,
      enableHotReload,
    );

    return <String, dynamic>{
      'appId': app.id,
      'deviceId': device.id,
      'directory': projectDirectory,
      'supportsRestart': isRestartSupported(enableHotReload, device)
    };
  }

  Future<AppInstance> startApp(
    Device device, String projectDirectory, String target, String route,
    DebuggingOptions options, bool enableHotReload, {
    String applicationBinary,
    String projectRootPath,
    String packagesFilePath,
    String projectAssets,
  }) async {
    if (device.isLocalEmulator && !isEmulatorBuildMode(options.buildMode))
      throw '${toTitleCase(getModeName(options.buildMode))} mode is not supported for emulators.';

    // We change the current working directory for the duration of the `start` command.
    final Directory cwd = fs.currentDirectory;
    fs.currentDirectory = fs.directory(projectDirectory);

    ResidentRunner runner;

    if (enableHotReload) {
      runner = new HotRunner(
        device,
        target: target,
        debuggingOptions: options,
        usesTerminalUI: false,
        applicationBinary: applicationBinary,
        projectRootPath: projectRootPath,
        packagesFilePath: packagesFilePath,
        projectAssets: projectAssets,
      );
    } else {
      runner = new ColdRunner(
        device,
        target: target,
        debuggingOptions: options,
        usesTerminalUI: false,
        applicationBinary: applicationBinary,
      );
    }

    final AppInstance app = new AppInstance(_getNewAppId(), runner: runner, logToStdout: daemon.logToStdout);
    _apps.add(app);
    _sendAppEvent(app, 'start', <String, dynamic>{
      'deviceId': device.id,
      'directory': projectDirectory,
      'supportsRestart': isRestartSupported(enableHotReload, device)
    });

    Completer<DebugConnectionInfo> connectionInfoCompleter;

    if (options.debuggingEnabled) {
      connectionInfoCompleter = new Completer<DebugConnectionInfo>();
      connectionInfoCompleter.future.then<Null>((DebugConnectionInfo info) {
        final Map<String, dynamic> params = <String, dynamic>{
          'port': info.httpUri.port,
          'wsUri': info.wsUri.toString(),
        };
        if (info.baseUri != null)
          params['baseUri'] = info.baseUri;
        _sendAppEvent(app, 'debugPort', params);
      });
    }
    final Completer<Null> appStartedCompleter = new Completer<Null>();
    appStartedCompleter.future.then<Null>((Null value) {
      _sendAppEvent(app, 'started');
    });

    await app._runInZone(this, () async {
      try {
        await runner.run(
          connectionInfoCompleter: connectionInfoCompleter,
          appStartedCompleter: appStartedCompleter,
          route: route,
        );
        _sendAppEvent(app, 'stop');
      } catch (error) {
        _sendAppEvent(app, 'stop', <String, dynamic>{'error': error.toString()});
      } finally {
        fs.currentDirectory = cwd;
        _apps.remove(app);
      }
    });

    return app;
  }

  bool isRestartSupported(bool enableHotReload, Device device) =>
      enableHotReload && device.supportsHotMode;

  Future<OperationResult> restart(Map<String, dynamic> args) async {
    final String appId = _getStringArg(args, 'appId', required: true);
    final bool fullRestart = _getBoolArg(args, 'fullRestart') ?? false;
    final bool pauseAfterRestart = _getBoolArg(args, 'pause') ?? false;

    final AppInstance app = _getApp(appId);
    if (app == null)
      throw "app '$appId' not found";

    return app._runInZone(this, () {
      return app.restart(fullRestart: fullRestart, pauseAfterRestart: pauseAfterRestart);
    });
  }

  Future<OperationResult> callServiceExtension(Map<String, dynamic> args) async {
    final String appId = _getStringArg(args, 'appId', required: true);
    final String methodName = _getStringArg(args, 'methodName');
    final Map<String, String> params = args['params'] ?? <String, String>{};

    final AppInstance app = _getApp(appId);
    if (app == null)
      throw "app '$appId' not found";

    final Isolate isolate = app.runner.currentView.uiIsolate;
    final Map<String, dynamic> result = await isolate.invokeFlutterExtensionRpcRaw(methodName, params: params);
    if (result == null)
      return new OperationResult(1, 'method not available: $methodName');

    if (result.containsKey('error'))
      return new OperationResult(1, result['error']);
    else
      return OperationResult.ok;
  }

  Future<bool> stop(Map<String, dynamic> args) async {
    final String appId = _getStringArg(args, 'appId', required: true);

    final AppInstance app = _getApp(appId);
    if (app == null)
      throw "app '$appId' not found";

    return app.stop().timeout(const Duration(seconds: 5)).then<bool>((_) {
      return true;
    }).catchError((dynamic error) {
      _sendAppEvent(app, 'log', <String, dynamic>{ 'log': '$error', 'error': true });
      app.closeLogger();
      _apps.remove(app);
      return false;
    });
  }

  Future<List<Map<String, dynamic>>> discover(Map<String, dynamic> args) async {
    final String deviceId = _getStringArg(args, 'deviceId', required: true);

    final Device device = daemon.deviceDomain._getDevice(deviceId);
    if (device == null)
      throw "device '$deviceId' not found";

    final List<DiscoveredApp> apps = await device.discoverApps();
    return apps.map((DiscoveredApp app) {
      return <String, dynamic>{
        'id': app.id,
        'observatoryDevicePort': app.observatoryPort,
        'diagnosticDevicePort': app.diagnosticPort,
      };
    }).toList();
  }

  AppInstance _getApp(String id) {
    return _apps.firstWhere((AppInstance app) => app.id == id, orElse: () => null);
  }

  void _sendAppEvent(AppInstance app, String name, [Map<String, dynamic> args]) {
    final Map<String, dynamic> eventArgs = <String, dynamic> { 'appId': app.id };
    if (args != null)
      eventArgs.addAll(args);
    sendEvent('app.$name', eventArgs);
  }
}

/// This domain lets callers list and monitor connected devices.
///
/// It exports a `getDevices()` call, as well as firing `device.added` and
/// `device.removed` events.
class DeviceDomain extends Domain {
  DeviceDomain(Daemon daemon) : super(daemon, 'device') {
    registerHandler('getDevices', getDevices);
    registerHandler('enable', enable);
    registerHandler('disable', disable);
    registerHandler('forward', forward);
    registerHandler('unforward', unforward);

    PollingDeviceDiscovery deviceDiscovery = new AndroidDevices();
    if (deviceDiscovery.supportsPlatform)
      _discoverers.add(deviceDiscovery);

    deviceDiscovery = new IOSDevices();
    if (deviceDiscovery.supportsPlatform)
      _discoverers.add(deviceDiscovery);

    deviceDiscovery = new IOSSimulators();
    if (deviceDiscovery.supportsPlatform)
      _discoverers.add(deviceDiscovery);

    for (PollingDeviceDiscovery discoverer in _discoverers) {
      discoverer.onAdded.listen((Device device) {
        sendEvent('device.added', _deviceToMap(device));
      });
      discoverer.onRemoved.listen((Device device) {
        sendEvent('device.removed', _deviceToMap(device));
      });
    }
  }

  final List<PollingDeviceDiscovery> _discoverers = <PollingDeviceDiscovery>[];

  Future<List<Device>> getDevices([Map<String, dynamic> args]) {
    final List<Device> devices = _discoverers.expand((PollingDeviceDiscovery discoverer) {
      return discoverer.devices;
    }).toList();
    return new Future<List<Device>>.value(devices);
  }

  /// Enable device events.
  Future<Null> enable(Map<String, dynamic> args) {
    for (PollingDeviceDiscovery discoverer in _discoverers)
      discoverer.startPolling();
    return new Future<Null>.value();
  }

  /// Disable device events.
  Future<Null> disable(Map<String, dynamic> args) {
    for (PollingDeviceDiscovery discoverer in _discoverers)
      discoverer.stopPolling();
    return new Future<Null>.value();
  }

  /// Forward a host port to a device port.
  Future<Map<String, dynamic>> forward(Map<String, dynamic> args) async {
    final String deviceId = _getStringArg(args, 'deviceId', required: true);
    final int devicePort = _getIntArg(args, 'devicePort', required: true);
    int hostPort = _getIntArg(args, 'hostPort');

    final Device device = daemon.deviceDomain._getDevice(deviceId);
    if (device == null)
      throw "device '$deviceId' not found";

    hostPort = await device.portForwarder.forward(devicePort, hostPort: hostPort);

    return <String, dynamic>{ 'hostPort': hostPort };
  }

  /// Removes a forwarded port.
  Future<Null> unforward(Map<String, dynamic> args) async {
    final String deviceId = _getStringArg(args, 'deviceId', required: true);
    final int devicePort = _getIntArg(args, 'devicePort', required: true);
    final int hostPort = _getIntArg(args, 'hostPort', required: true);

    final Device device = daemon.deviceDomain._getDevice(deviceId);
    if (device == null)
      throw "device '$deviceId' not found";

    return device.portForwarder.unforward(new ForwardedPort(hostPort, devicePort));
  }

  @override
  void dispose() {
    for (PollingDeviceDiscovery discoverer in _discoverers)
      discoverer.dispose();
  }

  /// Return the device matching the deviceId field in the args.
  Device _getDevice(String deviceId) {
    final List<Device> devices = _discoverers.expand((PollingDeviceDiscovery discoverer) {
      return discoverer.devices;
    }).toList();
    return devices.firstWhere((Device device) => device.id == deviceId, orElse: () => null);
  }

  /// Return a known matching device, or scan for devices if no known match is found.
  Device _getOrLocateDevice(String deviceId) {
    // Look for an already known device.
    final Device device = _getDevice(deviceId);
    if (device != null)
      return device;

    // Scan the different device providers for a match.
    for (PollingDeviceDiscovery discoverer in _discoverers) {
      final List<Device> devices = discoverer.pollingGetDevices();
      for (Device device in devices)
        if (device.id == deviceId)
          return device;
    }

    // No match found.
    return null;
  }
}

Stream<Map<String, dynamic>> get stdinCommandStream => stdin
  .transform(UTF8.decoder)
  .transform(const LineSplitter())
  .where((String line) => line.startsWith('[{') && line.endsWith('}]'))
  .map((String line) {
    line = line.substring(1, line.length - 1);
    return JSON.decode(line);
  });

void stdoutCommandResponse(Map<String, dynamic> command) {
  stdout.writeln('[${JSON.encode(command, toEncodable: _jsonEncodeObject)}]');
}

dynamic _jsonEncodeObject(dynamic object) {
  if (object is Device)
    return _deviceToMap(object);
  if (object is OperationResult)
    return _operationResultToMap(object);
  return object;
}

Map<String, dynamic> _deviceToMap(Device device) {
  return <String, dynamic>{
    'id': device.id,
    'name': device.name,
    'platform': getNameForTargetPlatform(device.targetPlatform),
    'emulator': device.isLocalEmulator
  };
}

Map<String, dynamic> _operationResultToMap(OperationResult result) {
  return <String, dynamic>{
    'code': result.code,
    'message': result.message
  };
}

dynamic _toJsonable(dynamic obj) {
  if (obj is String || obj is int || obj is bool || obj is Map<dynamic, dynamic> || obj is List<dynamic> || obj == null)
    return obj;
  if (obj is Device)
    return obj;
  if (obj is OperationResult)
    return obj;
  return '$obj';
}

class NotifyingLogger extends Logger {
  final StreamController<LogMessage> _messageController = new StreamController<LogMessage>.broadcast();

  Stream<LogMessage> get onMessage => _messageController.stream;

  @override
  void printError(String message, [StackTrace stackTrace]) {
    _messageController.add(new LogMessage('error', message, stackTrace));
  }

  @override
  void printStatus(
    String message,
    { bool emphasis: false, bool newline: true, String ansiAlternative, int indent }
  ) {
    _messageController.add(new LogMessage('status', message));
  }

  @override
  void printTrace(String message) {
    // This is a lot of traffic to send over the wire.
  }

  @override
  Status startProgress(String message, { String progressId, bool expectSlowOperation: false }) {
    printStatus(message);
    return new Status();
  }

  void dispose() {
    _messageController.close();
  }
}

/// A running application, started by this daemon.
class AppInstance {
  AppInstance(this.id, { this.runner, this.logToStdout = false });

  final String id;
  final ResidentRunner runner;
  final bool logToStdout;

  _AppRunLogger _logger;

  Future<OperationResult> restart({ bool fullRestart: false, bool pauseAfterRestart: false }) {
    return runner.restart(fullRestart: fullRestart, pauseAfterRestart: pauseAfterRestart);
  }

  Future<Null> stop() => runner.stop();

  void closeLogger() {
    _logger.close();
  }

  dynamic _runInZone(AppDomain domain, dynamic method()) {
    _logger ??= new _AppRunLogger(domain, this, logToStdout: logToStdout);

    final AppContext appContext = new AppContext();
    appContext.setVariable(Logger, _logger);
    return appContext.runInZone(method);
  }
}

/// A [Logger] which sends log messages to a listening daemon client.
class _AppRunLogger extends Logger {
  _AppRunLogger(this.domain, this.app, { this.logToStdout: false });

  AppDomain domain;
  final AppInstance app;
  final bool logToStdout;
  int _nextProgressId = 0;

  @override
  void printError(String message, [StackTrace stackTrace]) {
    if (logToStdout) {
      stderr.writeln(message);
      if (stackTrace != null)
        stderr.writeln(stackTrace.toString().trimRight());
    } else {
      if (stackTrace != null) {
        _sendLogEvent(<String, dynamic>{
          'log': message,
          'stackTrace': stackTrace.toString(),
          'error': true
        });
      } else {
        _sendLogEvent(<String, dynamic>{
          'log': message,
          'error': true
        });
      }
    }
  }

  @override
  void printStatus(
    String message,
    { bool emphasis: false, bool newline: true, String ansiAlternative, int indent }
  ) {
    if (logToStdout) {
      print(message);
    } else {
      _sendLogEvent(<String, dynamic>{ 'log': message });
    }
  }

  @override
  void printTrace(String message) { }

  Status _status;

  @override
  Status startProgress(String message, { String progressId, bool expectSlowOperation: false }) {
    // Ignore nested progresses; return a no-op status object.
    if (_status != null)
      return new Status();

    final int id = _nextProgressId++;

    _sendProgressEvent(<String, dynamic>{
      'id': id.toString(),
      'progressId': progressId,
      'message': message,
    });

    _status = new _AppLoggerStatus(this, id, progressId);
    return _status;
  }

  void close() {
    domain = null;
  }

  void _sendLogEvent(Map<String, dynamic> event) {
    if (domain == null)
      printStatus('event sent after app closed: $event');
    else
      domain._sendAppEvent(app, 'log', event);
  }

  void _sendProgressEvent(Map<String, dynamic> event) {
    if (domain == null)
      printStatus('event sent after app closed: $event');
    else
      domain._sendAppEvent(app, 'progress', event);
  }
}

class _AppLoggerStatus implements Status {
  _AppLoggerStatus(this.logger, this.id, this.progressId);

  final _AppRunLogger logger;
  final int id;
  final String progressId;

  @override
  void stop() {
    logger._status = null;
    _sendFinished();
  }

  @override
  void cancel() {
    logger._status = null;
    _sendFinished();
  }

  void _sendFinished() {
    logger._sendProgressEvent(<String, dynamic>{
      'id': id.toString(),
      'progressId': progressId,
      'finished': true
    });
  }
}

class LogMessage {
  final String level;
  final String message;
  final StackTrace stackTrace;

  LogMessage(this.level, this.message, [this.stackTrace]);
}
