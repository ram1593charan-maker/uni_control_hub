import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:synergy_client_dart/synergy_client_dart.dart';
import 'package:uni_control_hub/app/client/report_handler.dart';
import 'package:uni_control_hub/app/data/logger.dart';
import 'package:uni_control_hub/app/models/screen_link.dart';
import 'package:uni_control_hub/app/services/storage_service.dart';

class ClientScreen extends ScreenInterface {
  late final StorageService _storageService = StorageService.to;
  Function(int x, int y)? onMouseMove;
  final VoidCallback onConnectCallback;
  final VoidCallback onDisconnectCallback;
  final Function(String error) onErrorCallback;
  final Function(List<int>) inputReportCallback;
  final Direction direction;

  ClientScreen({
    required this.direction,
    required this.inputReportCallback,
    required this.onConnectCallback,
    required this.onDisconnectCallback,
    required this.onErrorCallback,
  });

  List<int> lastSent = List.filled(4, 0);
  int relativeX = 0;
  int relativeY = 0;
  int? buttonPressed;

  // Mouse movement is batched and flushed every few ms. Each HID report
  // carries at most 127 units per axis, larger deltas are split.
  static const Duration _mouseFlushInterval = Duration(milliseconds: 8);
  static const int _maxDelta = 127;
  Timer? _mouseFlushTimer;
  int _pendingX = 0;
  int _pendingY = 0;

  void _queueMouseMove(int dx, int dy) {
    _pendingX += dx;
    _pendingY += dy;
    _mouseFlushTimer ??= Timer(_mouseFlushInterval, _flushMouseMove);
  }

  /// Sends pending movement now. Safe to call when nothing is pending.
  void _flushMouseMove() {
    _mouseFlushTimer?.cancel();
    _mouseFlushTimer = null;
    while (_pendingX != 0 || _pendingY != 0) {
      final stepX = _clampDelta(_pendingX);
      final stepY = _clampDelta(_pendingY);
      _pendingX -= stepX;
      _pendingY -= stepY;
      _addInputReport(_mouseReport(buttonPressed ?? 0, stepX, stepY, 0));
    }
  }

  int _clampDelta(int value) => value.clamp(-_maxDelta, _maxDelta).toInt();

  Uint8List _mouseReport(int buttons, int x, int y, int wheel) {
    var reportData = Uint8List(5);
    reportData[0] = 0x02; // Report ID
    reportData[1] = buttons; // Button state
    reportData[2] = x; // X movement
    reportData[3] = y; // Y movement
    reportData[4] = wheel; // Wheel movement
    return reportData;
  }

  @override
  void mouseDown(int buttonID) {
    _flushMouseMove();
    _addInputReport(_mouseReport(buttonID, 0, 0, 0));
    buttonPressed = buttonID;
  }

  @override
  void mouseUp(int buttonID) {
    _flushMouseMove();
    _addInputReport(_mouseReport(0, 0, 0, 0));
    if (buttonPressed == buttonID) {
      buttonPressed = null;
    } else {
      buttonPressed = buttonPressed;
    }
  }

  @override
  void mouseMove(int x, int y) {
    _queueMouseMove(x - relativeX, y - relativeY);
    relativeX = x;
    relativeY = y;
    onMouseMove?.call(x, y);
  }

  @override
  void mouseRelativeMove(int x, int y) {
    _queueMouseMove(x, y);
    relativeX = x;
    relativeY = y;
  }

  @override
  void mouseWheel(int x, int y) {
    int wheel = x != 0 ? x : y;
    // convert wheel in +1 or -1
    if (_storageService.invertMouseScroll) {
      wheel = -wheel;
    }

    if (wheel > 0) {
      wheel = -1;
    } else if (wheel < 0) {
      wheel = 1;
    }

    _flushMouseMove();
    _addInputReport(_mouseReport(0, 0, 0, wheel));
  }

  @override
  CursorPosition getCursorPos() => CursorPosition(0, 0);

  @override
  RectObj getShape() {
    Size size = _storageService.clientDefaultSize;
    return RectObj(width: size.width, height: size.height);
  }

  @override
  void keyDown(int keyEventID, int mask, int button) async {
    // Handle Media Keys
    int? mediaKey = mediaKeyToByte(keyEventID);
    if (mediaKey != null) {
      _addInputReport([0x03, mediaKey, 0x00]);
      return;
    }

    // Handle Keyboard Keys
    int? code = keyCodeToByte(keyEventID);

    if (isPasteCommand(mask, code)) {
      String? clipboard = await getClipBoardData();
      if (clipboard != null) {
        await _sendText(clipboard);
        return;
      }
    }

    if (code == null) return;
    final List<int> report = List<int>.filled(9, 0);
    report[0] = 0x01; // Report ID
    report[1] = maskToByte(mask);
    report[3] = code;
    _addInputReport(report);
  }

  @override
  void keyRepeat(int keyEventID, int mask, int count, int button) {}

  @override
  void keyUp(int keyEventID, int mask, int button) {
    int? mediaKey = mediaKeyToByte(keyEventID);
    if (mediaKey != null) {
      _addInputReport([0x03, 0x00, 0x00]);
      return;
    }
    List<int> report = List<int>.filled(9, 0);
    report[0] = 0x01; // Report ID
    _addInputReport(report);
  }

  @override
  void enter(int x, int y, int sequenceNumber, int toggleMask) {
    // reset relative mouse position
    relativeX = x;
    relativeY = y;
  }

  @override
  bool leave() {
    logInfo("ClientScreen: leave");
    switch (direction) {
      case Direction.left:
        _moveMouseMultipleEvents(x: 4);
        break;
      case Direction.right:
        _moveMouseMultipleEvents(x: -4);
        break;
      case Direction.up:
        _moveMouseMultipleEvents(y: 4);
        break;
      case Direction.down:
        _moveMouseMultipleEvents(y: -4);
        break;
    }
    return true;
  }

  @override
  void onConnect() => onConnectCallback();

  @override
  void onDisconnect() => onDisconnectCallback();

  @override
  void onError(String error) => onErrorCallback(error);

  Future<void> _sendText(String text) async {
    final List<int> report = List<int>.filled(9, 0);
    report[0] = 0x01;
    for (int i = 0; i < text.length; i++) {
      String char = text[i];
      int? byte = textToByte(char);
      if (byte == null) continue;
      report[1] = textToMask(char);
      report[3] = byte;
      await _addInputReport(report);
    }
  }

  void _moveMouseMultipleEvents({int? x, int? y, int count = 100}) {
    for (int i = 0; i < count; i++) {
      var reportData = Uint8List(5);
      reportData[0] = 0x02; // Report ID
      reportData[1] = 0; // Button state
      reportData[2] = x ?? 0; // X movement
      reportData[3] = y ?? 0; // Y movement
      reportData[4] = 0; // Wheel movement
      _addInputReport(reportData);
    }
  }

  Future<void> _addInputReport(List<int> inputReport) =>
      inputReportCallback(inputReport);
}
