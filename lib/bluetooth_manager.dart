import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart' as btc;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Model for Discovered Device
class DiscoveredDevice {
  final String id;
  final String name;
  final int rssi;
  final dynamic originalDevice;

  DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
    this.originalDevice,
  });
}

/// Web Bluetooth State Manager for Otto DIY Robot
class BluetoothManager extends ChangeNotifier {
  static final BluetoothManager _instance = BluetoothManager._internal();
  factory BluetoothManager() => _instance;

  BluetoothManager._internal() {
    _loadPreferences();
  }

  // Bluetooth Classic (HC-05 / SPP) connection. Typed as dynamic on purpose.
  final btc.FlutterClassicBluetooth _classic = btc.FlutterClassicBluetooth();
  dynamic _connection;
  StreamSubscription? _dataSubscription;
  String _rxBuffer = '';

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  List<DiscoveredDevice> _devices = [];
  List<DiscoveredDevice> get devices => _devices;

  DiscoveredDevice? _connectedDevice;
  DiscoveredDevice? get connectedDevice => _connectedDevice;

  String? _activeMode;
  String? get activeMode => _activeMode;


  String? _pendingCommand;
  bool _isSending = false;

  Timer? _distanceClearTimer;
  double? _lastDistance;
  double? get lastDistance => _lastDistance;

  bool _isPollingUltrasound = false;
  bool get isPollingUltrasound => _isPollingUltrasound;
  Timer? _ultrasoundPollTimer;

  Timer? _lineSensorClearTimer;
  String? _lastLineSensorState;
  String? get lastLineSensorState => _lastLineSensorState;

  bool _isPollingLineSensor = false;
  bool get isPollingLineSensor => _isPollingLineSensor;
  Timer? _lineSensorPollTimer;

  String? _lastWheelCalib;
  String? get lastWheelCalib => _lastWheelCalib;

  static const Map<int, String> availableSounds = {
    0: 'No Sound',
    1: 'Connection',
    2: 'Disconnection',
    3: 'Button Pushed',
    4: 'Mode 1',
    5: 'Mode 2',
    6: 'Surprise',
    7: 'OhOoh',
    9: 'Cuddly',
    10: 'Sleeping',
    12: 'Happy',
    13: 'Super Happy',
    14: 'Sad',
    15: 'Confused',
    17: 'Fart 1',
    18: 'Fart 2',
    19: 'Fart 3',
  };

  int _avoidanceDistance = 15;
  int get avoidanceDistance => _avoidanceDistance;

  int _avoidanceSound = 0; // Default to 0 (No Sound)
  int get avoidanceSound => _avoidanceSound;

  int _lineSteering = 100; // Default 100% steer sharpness (original hard spin)
  int get lineSteering => _lineSteering;

  int _speedIndex = 2; // Default to speed index 2
  int get speedIndex => _speedIndex;

  set speedIndex(int value) {
    if (value >= 0 && value <= 5) {
      _speedIndex = value;
      notifyListeners();

      if (_activeMode != null) {
        sendCommand('$_activeMode$_speedIndex\n');
      }
    }
  }

  String get lineSensorLabel {
    if (_lastLineSensorState == null) return 'Line Sensors';
    switch (_lastLineSensorState) {
      case '0,0':
        return 'Sensors: L:⚪ R:⚪ (Forward)';
      case '1,0':
        return 'Sensors: L:⚫ R:⚪ (Turn Left)';
      case '0,1':
        return 'Sensors: L:⚪ R:⚫ (Turn Right)';
      case '1,1':
        return 'Sensors: L:⚫ R:⚫ (Stop)';
      default:
        return 'Sensors: $_lastLineSensorState';
    }
  }

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  final List<String> _consoleLogs = ["Bluetooth Classic (HC-05) manager initialized."];
  List<String> get consoleLogs => _consoleLogs;

  void addLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    _consoleLogs.insert(0, "[$timestamp] $message");
    if (_consoleLogs.length > 50) _consoleLogs.removeLast();
    notifyListeners();
  }

  void _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _avoidanceDistance = prefs.getInt('avoidance_distance') ?? 15;
      _avoidanceSound = prefs.getInt('avoidance_sound') ?? 0;
      _lineSteering = prefs.getInt('line_steering') ?? 100;
      notifyListeners();
    } catch (_) {}
  }

  void setAvoidanceDistance(int dist) async {
    if (dist < 5) dist = 5;
    if (dist > 40) dist = 40;
    if (_avoidanceDistance != dist) {
      _avoidanceDistance = dist;
      notifyListeners();

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('avoidance_distance', dist);
      } catch (_) {}

      if (_connectedDevice != null) {
        sendCommand('avoidance_dist$dist\n');
      }
    }
  }

  void setAvoidanceSound(int soundId) async {
    if (_avoidanceSound != soundId) {
      _avoidanceSound = soundId;
      notifyListeners();

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('avoidance_sound', soundId);
      } catch (_) {}

      if (_connectedDevice != null) {
        sendCommand('avoidance_sound$soundId\n');
      }
    }
  }

  void setLineSteering(int val) async {
    if (val < 0) val = 0;
    if (val > 100) val = 100;
    if (_lineSteering != val) {
      _lineSteering = val;
      notifyListeners();

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('line_steering', val);
      } catch (_) {}

      if (_connectedDevice != null) {
        sendCommand('line_steer$val\n');
      }
    }
  }


  /// Classic Bluetooth cannot "scan" like BLE. We list the devices that are
  /// already paired in Android Bluetooth settings (pair the HC-05 there first).
  Future<void> startScan() async {
    _devices.clear();
    _errorMessage = null;
    _isScanning = true;
    notifyListeners();
    addLog("Loading paired Bluetooth devices...");

    try {
      await Permission.bluetoothConnect.request();
      await Permission.bluetoothScan.request();

      final dynamic paired = await _classic.getPairedDevices();
      final List<DiscoveredDevice> found = [];
      for (final dynamic d in paired) {
        final String address = d.address.toString();
        String name = address;
        try {
          final dynamic n = d.displayName;
          if (n != null && n.toString().isNotEmpty) name = n.toString();
        } catch (_) {}
        found.add(
          DiscoveredDevice(
            id: address,
            name: name,
            rssi: 0,
            originalDevice: d,
          ),
        );
      }
      _devices = found;
      addLog("Found ${found.length} paired device(s).");
      if (found.isEmpty) {
        _errorMessage =
            "No paired devices. Pair the HC-05 in Android Bluetooth settings first (PIN 1234 or 0000), then try again.";
      }
    } catch (e) {
      _errorMessage = "Could not list paired devices: $e";
      addLog("Error: $_errorMessage");
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    _isScanning = false;
    notifyListeners();
  }

  Future<void> _cleanupConnection() async {
    _connectedDevice = null;
    _connection = null;
    _pendingCommand = null;
    _activeMode = null;
    _rxBuffer = '';

    await _dataSubscription?.cancel();
    _dataSubscription = null;

    _distanceClearTimer?.cancel();
    _distanceClearTimer = null;
    _lastDistance = null;

    _isPollingUltrasound = false;
    _ultrasoundPollTimer?.cancel();
    _ultrasoundPollTimer = null;

    _lineSensorClearTimer?.cancel();
    _lineSensorClearTimer = null;
    _lastLineSensorState = null;

    _isPollingLineSensor = false;
    _lineSensorPollTimer?.cancel();
    _lineSensorPollTimer = null;
  }

  /// Opens an RFCOMM (SPP) serial connection to the paired HC-05.
  Future<void> connect(DiscoveredDevice device) async {
    _isConnecting = true;
    _errorMessage = null;
    notifyListeners();
    addLog("Connecting to ${device.name} (${device.id})...");

    try {
      await Permission.bluetoothConnect.request();

      final dynamic conn = await _classic.connect(address: device.id);
      _connection = conn;
      _rxBuffer = '';

      await _dataSubscription?.cancel();
      _dataSubscription = conn.input.listen(
        (dynamic value) => _onBytes(List<int>.from(value)),
        onError: (e) {
          addLog("Receive error: $e");
        },
        onDone: () async {
          if (_connectedDevice?.id == device.id) {
            addLog("Disconnected from ${device.name}.");
            await _cleanupConnection();
            notifyListeners();
          }
        },
      );

      _connectedDevice = device;
      addLog("Connected. Otto ready.");

      // Flush any buffered command
      if (_pendingCommand != null) {
        final cmdToSend = _pendingCommand!;
        _pendingCommand = null;
        addLog("Flushing buffered initial command: '${cmdToSend.trim()}'");
        await sendCommand(cmdToSend);
      }
    } catch (e) {
      _connection = null;
      _connectedDevice = null;
      _errorMessage =
          "Connection failed: $e\nMake sure the robot is switched on, the HC-05 is paired, and no other app is connected to it.";
      addLog("Error: $_errorMessage");
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  /// Collects incoming bytes and handles complete lines.
  void _onBytes(List<int> value) {
    _rxBuffer += String.fromCharCodes(value);
    while (true) {
      final idx = _rxBuffer.indexOf('\n');
      if (idx < 0) break;
      final line = _rxBuffer.substring(0, idx).trim();
      _rxBuffer = _rxBuffer.substring(idx + 1);
      if (line.isNotEmpty) _handleLine(line);
    }
    if (_rxBuffer.length > 512) _rxBuffer = '';
  }

  void _handleLine(String rawData) {
    if (rawData.startsWith("LINE:")) {
      _lastLineSensorState = rawData.substring(5).trim();
      addLog("Line status received: $_lastLineSensorState");
      notifyListeners();

      _lineSensorClearTimer?.cancel();
      if (!_isPollingLineSensor) {
        _lineSensorClearTimer = Timer(const Duration(seconds: 5), () {
          _lastLineSensorState = null;
          notifyListeners();
        });
      }
    } else if (rawData.startsWith("WHEEL_CALIB:")) {
      _lastWheelCalib = rawData.substring(12).trim();
      addLog("Wheel calibration received: $_lastWheelCalib");
      notifyListeners();
    } else {
      final double? dist = double.tryParse(rawData);
      if (dist != null) {
        _lastDistance = dist;
        addLog("Distance received: ${dist.toStringAsFixed(1)} cm");
        notifyListeners();

        _distanceClearTimer?.cancel();
        if (!_isPollingUltrasound) {
          _distanceClearTimer = Timer(const Duration(seconds: 5), () {
            _lastDistance = null;
            notifyListeners();
          });
        }
      }
    }
  }

  Future<void> disconnect() async {
    if (_connectedDevice == null) return;
    final name = _connectedDevice!.name;
    addLog("Disconnecting from $name...");

    try {
      await _connection?.close();
    } catch (e) {
      addLog("Disconnect error: $e");
    } finally {
      await _cleanupConnection();
      notifyListeners();
    }
  }

  Future<void> _writeRaw(String text) async {
    await _connection.output.writeString(text);
  }

  /// Sends command over the Bluetooth Classic serial link using Last-In-Wins single-slot buffering
  Future<void> sendCommand(String command) async {
    _pendingCommand = command;

    final cmdClean = command.trim().toLowerCase();
    if (!cmdClean.startsWith('ultrasound') && !cmdClean.startsWith('linesensor')) {
      if (_isPollingUltrasound) stopUltrasoundPolling();
      if (_isPollingLineSensor) stopLineSensorPolling();
    }

    if (cmdClean.startsWith('avoidance')) {
      _activeMode = 'avoidance';
    } else if (cmdClean.startsWith('line_follower')) {
      _activeMode = 'line_follower';
    } else if (cmdClean.startsWith('force')) {
      _activeMode = 'force';
    } else if (cmdClean.startsWith('stop') ||
        cmdClean.startsWith('forward') ||
        cmdClean.startsWith('backward') ||
        cmdClean.startsWith('left') ||
        cmdClean.startsWith('right') ||
        cmdClean.startsWith('happy') ||
        cmdClean.startsWith('victory') ||
        cmdClean.startsWith('sad') ||
        cmdClean.startsWith('sleeping') ||
        cmdClean.startsWith('confused') ||
        cmdClean.startsWith('fail') ||
        cmdClean.startsWith('fart') ||
        cmdClean.startsWith('love') ||
        cmdClean.startsWith('fretful') ||
        cmdClean.startsWith('magic') ||
        cmdClean.startsWith('sing') ||
        cmdClean.startsWith('walk_test') ||
        cmdClean.startsWith('ultrasound')) {
      _activeMode = null;
    }

    notifyListeners();

    if (_connectedDevice == null || _connection == null) return;
    if (_isSending) return;

    _isSending = true;

    try {
      while (_pendingCommand != null &&
          _connectedDevice != null &&
          _connection != null) {
        final cmdToSend = _pendingCommand!;
        _pendingCommand = null;

        addLog("Sent Command: '${cmdToSend.trim()}'");

        await _writeRaw(cmdToSend);

        await Future.delayed(const Duration(milliseconds: 30));
      }
    } catch (e) {
      addLog("Send failed: $e");
      await disconnect();
    } finally {
      _isSending = false;
    }
  }

  void toggleUltrasoundPolling() {
    if (_isPollingUltrasound) {
      stopUltrasoundPolling();
    } else {
      startUltrasoundPolling();
    }
  }

  void startUltrasoundPolling() {
    if (_connectedDevice == null) return;
    sendCommand('stop2\n');
    _isPollingUltrasound = true;
    _lastDistance = null;
    notifyListeners();

    _ultrasoundPollTimer?.cancel();
    _ultrasoundPollTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (_connectedDevice == null) {
        stopUltrasoundPolling();
        return;
      }

      try {
        await _writeRaw("ultrasound2\n");
        addLog("Polling ultrasound...");
      } catch (e) {
        addLog("Ultrasound polling failed: $e");
        await disconnect();
      }
    });
  }

  void stopUltrasoundPolling() {
    if (!_isPollingUltrasound) return;
    _isPollingUltrasound = false;
    _ultrasoundPollTimer?.cancel();
    _ultrasoundPollTimer = null;
    _lastDistance = null;
    notifyListeners();
  }

  void toggleLineSensorPolling() {
    if (_isPollingLineSensor) {
      stopLineSensorPolling();
    } else {
      startLineSensorPolling();
    }
  }

  void startLineSensorPolling() {
    if (_connectedDevice == null) return;
    sendCommand('stop2\n');
    _isPollingLineSensor = true;
    _lastLineSensorState = null;
    notifyListeners();

    _lineSensorPollTimer?.cancel();
    _lineSensorPollTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (_connectedDevice == null) {
        stopLineSensorPolling();
        return;
      }

      try {
        await _writeRaw("linesensor2\n");
        addLog("Polling line sensors...");
      } catch (e) {
        addLog("Line sensor polling failed: $e");
        await disconnect();
      }
    });
  }

  void stopLineSensorPolling() {
    if (!_isPollingLineSensor) return;
    _isPollingLineSensor = false;
    _lineSensorPollTimer?.cancel();
    _lineSensorPollTimer = null;
    _lastLineSensorState = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _distanceClearTimer?.cancel();
    _ultrasoundPollTimer?.cancel();
    _lineSensorClearTimer?.cancel();
    _lineSensorPollTimer?.cancel();
    super.dispose();
  }
}
