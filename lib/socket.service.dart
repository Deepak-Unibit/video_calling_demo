import 'dart:async';
import 'package:logger/logger.dart';
import 'package:socket_io_client/socket_io_client.dart';
import 'package:video_calling_demo/api/app.const.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();
  static SocketService get instance => _instance;

  Socket? socket;
  final StreamController<Map<String, dynamic>> streamController = StreamController<Map<String, dynamic>>.broadcast();
  bool isSocketConnected = false;

  void getSocketConnection() {
    if (isSocketConnected) return;

    Logger().i('Establishing socket connection...');

    try {
      socket = io(
        'http://192.168.1.9:3000',
        OptionBuilder()
            .setTransports(['websocket'])
            .disableAutoConnect()
            .enableReconnection()
            .setAuth({'token': AppConst.authToken})
            .build(),
      );
      socket?.connect();

      socket?.on('connect', (_) {
        isSocketConnected = true;
        Logger().i('Socket connected: ${socket?.id}');
      });

      socket?.on('connect_error', (data) {
        isSocketConnected = false;
        Logger().e('Socket connection error: $data');
      });

      socket?.on('disconnect', (data) {
        isSocketConnected = false;
        Logger().i('Socket disconnected: $data');
      });

    } catch (e) {
      Logger().e('Socket connection error: $e');
    }
  }
}
