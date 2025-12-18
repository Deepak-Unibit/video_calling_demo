import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart' hide navigator;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_calling_demo/api/key.const.dart';
import 'package:video_calling_demo/auth.service.dart';
import 'package:video_calling_demo/socket.service.dart';
import 'package:video_calling_demo/video_player_screen.dart';

class HomeController {
  AuthService authService = Get.find<AuthService>();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCVideoRenderer localRenderer = RTCVideoRenderer();
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  Function? onRemoteStream;
  String id = "";
  String callId = "";
  String timeString = "";
  late Timer _timer;
  Function? onTimerUpdate;
  String statusString = "";
  Function? onStatusUpdate;
  String? incomingCallId;
  Function? onIncomingCall;
  Function? onCallEnded;

  MediaRecorder? _mediaRecorder;
  String? _recordingFilePath;

  String targetUserId = "6943e3b1c11bec529932e670";

  List<RTCIceCandidate> candidateQueue = [];

  Future<void> initializeRenderers() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': true});
    localRenderer.srcObject = _localStream;

    var iceServers = await authService.getTurnCredentials();

    Logger().i(iceServers);

    _peerConnection = await createPeerConnection({'iceServers': iceServers, 'sdpSemantics': 'unified-plan'});

    _localStream!.getTracks().forEach((track) => _peerConnection!.addTrack(track, _localStream!));

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        final remoteStream = event.streams[0];
        remoteRenderer.srcObject = remoteStream;
        onRemoteStream?.call();

        remoteStream.getTracks().forEach((track) {
          _localStream!.addTrack(track);
        });
      }
    };

    SocketService.instance.getSocketConnection();
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    final socket = SocketService.instance.socket;

    socket?.on(KeyConst.callError, (data) {
      statusString = "Call error: ${data['message']}";
      onStatusUpdate?.call();
    });

    socket?.on(KeyConst.callRinging, (data) async {
      statusString = "Ringing...";
      onStatusUpdate?.call();
    });

    // MATCHING IMAGE: Listen for incoming call
    socket?.on(KeyConst.callIncoming, (data) async {
      incomingCallId = data['callId'];
      statusString = "Show Accept";
      onStatusUpdate?.call();
      ringingCall(data['callId']);
      callId = data['callId'];
      // acceptCall(data['callId']);
    });

    // MATCHING IMAGE: Listen for accepted call to start WebRTC
    socket?.on(KeyConst.callAccepted, (data) async {
      bool isCaller = data['isCaller'] ?? false;
      statusString = "Call accepted";
      onStatusUpdate?.call();

      if (isCaller) {
        print("I am the caller, making offer...");
        await _makeOffer(data['callId']);
      } else {
        print("I am the callee, waiting for offer...");
      }

      int timeStamp = data['startTimestamp'];
      startCallTimer(timeStamp);
    });

    socket?.on(KeyConst.callOffer, (data) async {
      statusString = "Received call offer";
      onStatusUpdate?.call();

      var offer = RTCSessionDescription(data['sdp'], 'offer');
      await _peerConnection!.setRemoteDescription(offer);
      for (var candidate in candidateQueue) {
        await _peerConnection!.addCandidate(candidate);
      }
      candidateQueue.clear();
      await _makeAnswer(data['callId']);
    });

    socket?.on(KeyConst.callAnswer, (data) async {
      try {
        if (data['sdp'] == null) {
          print("Error: Received malformed offer data");
          return;
        }

        // Ensure the type is exactly "offer" or "answer"
        RTCSessionDescription description = RTCSessionDescription(data['sdp'], 'answer');

        if (_peerConnection!.signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          await _peerConnection!.setRemoteDescription(description);
        } else {
          return;
        }

        for (var candidate in candidateQueue) {
          await _peerConnection!.addCandidate(candidate);
        }
        candidateQueue.clear();

        callId = data['callId'];
        statusString = "Call established";
        onStatusUpdate?.call();
        await startRecording();
      } on Exception catch (e) {}
    });

    socket?.on(KeyConst.callEnded, (data) async {
      await stopRecording();
      statusString = "Call ended";
      onStatusUpdate?.call();
      await _peerConnection?.close();
      _peerConnection = null;
      if (_timer != null) {
        _timer.cancel();
      }
      timeString = "";
      callId = "";
      incomingCallId = null;
      onCallEnded?.call();

      // exit(0);
    });

    socket?.on(KeyConst.callIceCandidate, (data) async {
      if (_peerConnection?.getRemoteDescription() != null) {
        await _peerConnection!.addCandidate(RTCIceCandidate(data['candidate']['candidate'], data['candidate']['sdpMid'], data['candidate']['sdpMLineIndex']));
      } else {
        candidateQueue.add(RTCIceCandidate(data['candidate']['candidate'], data['candidate']['sdpMid'], data['candidate']['sdpMLineIndex']));
      }
    });
  }

  // --- ACTIONS ---

  // MATCHING IMAGE: Initiate Call
  void initiateCall() {
    statusString = "Calling $targetUserId";
    onStatusUpdate?.call();
    SocketService.instance.socket?.emit('call:initiate', {'calleeId': targetUserId});
  }

  void ringingCall(String callerId) {
    print("${statusString}");
    SocketService.instance.socket?.emit(KeyConst.callRinging, {'callId': callerId});
  }

  // MATCHING IMAGE: Accept Call
  void acceptCall(String callId) {
    statusString = "Accepting call...";
    incomingCallId = null;
    onStatusUpdate?.call();
    SocketService.instance.socket?.emit(KeyConst.callAccept, {'callId': callId});
  }

  void declineCall(String callId) {
    statusString = "Call declined";
    incomingCallId = null;
    onStatusUpdate?.call();
    SocketService.instance.socket?.emit(KeyConst.callEnd, {'callId': callId});
    onCallEnded?.call();
  }

  Future<void> _makeOffer(String callId) async {
    statusString = "Creating call offer...";
    onStatusUpdate?.call();

    Map<String, dynamic> constraints = {
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [],
    };

    RTCSessionDescription offer = await _peerConnection!.createOffer(constraints);
    await _peerConnection!.setLocalDescription(offer);

    SocketService.instance.socket?.emit(KeyConst.callOffer, {"callId": callId, "sdp": offer.sdp, "type": offer.type});

    _peerConnection?.onIceCandidate = (candidate) {
      SocketService.instance.socket?.emit(KeyConst.callIceCandidate, {'candidate': candidate.toMap(), 'callId': callId});
    };
  }

  Future<void> _makeAnswer(String callId) async {
    statusString = "Creating call answer...";
    onStatusUpdate?.call();

    Map<String, dynamic> constraints = {
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [],
    };
    RTCSessionDescription answer = await _peerConnection!.createAnswer(constraints);
    await _peerConnection!.setLocalDescription(answer);

    statusString = "Call established";
    onStatusUpdate?.call();

    SocketService.instance.socket?.emit(KeyConst.callAnswer, {"callId": callId, "sdp": answer.sdp, "type": answer.type});
    await startRecording();
  }

  Future<void> endCall() async {
    statusString = "Ending call...";
    onStatusUpdate?.call();

    SocketService.instance.socket?.emit(KeyConst.callEnd, {'callId': callId});
    await _peerConnection?.close();

    if (_timer != null) {
      _timer.cancel();
    }
    timeString = "";
    callId = "";
    incomingCallId = null;
    onTimerUpdate?.call();
    statusString = "Call ended";
    onStatusUpdate?.call();
    onCallEnded?.call();

    await stopRecording();
    // exit(0);
  }

  void startCallTimer(int startTimeStamp) {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final duration = Duration(milliseconds: now - startTimeStamp);

      timeString = "${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}";
      onTimerUpdate?.call();
    });
  }

  Future<void> startRecording() async {
    _mediaRecorder = MediaRecorder();

    final directory = await getTemporaryDirectory();
    _recordingFilePath = '${directory.path}/call_${DateTime.now().millisecondsSinceEpoch}.mp4';

    await _mediaRecorder!.start(_recordingFilePath!, videoTrack: localRenderer.srcObject!.getVideoTracks()[0], audioChannel: RecorderAudioChannel.INPUT);

    Logger().i("Recording started: $_recordingFilePath");
  }

  Future<void> stopRecording() async {
    if (_mediaRecorder != null) {
      await _mediaRecorder!.stop();
      Logger().i("Recording saved at: $_recordingFilePath");
      _mediaRecorder = null;
      Navigator.push(Get.context!, MaterialPageRoute(builder: (context) => VideoPlayerScreen(videoPath: _recordingFilePath!)));
    }
  }
}
