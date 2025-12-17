import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:video_calling_demo/api/key.const.dart';
import 'package:video_calling_demo/socket.service.dart';

class HomeController {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCVideoRenderer localRenderer = RTCVideoRenderer();
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  Function? onRemoteStream;

  String callId = "";
  String timeString = "";
  late Timer _timer;
  Function? onTimerUpdate;
  String statusString = "Ready to call";
  Function? onStatusUpdate;

  List<RTCIceCandidate> candidateQueue = [];

  final textEditingController = TextEditingController(text: "69425a3818b7ca50b9f1e662");

  Future<void> initializeRenderers() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    localRenderer.srcObject = _localStream;

    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });

    _localStream!.getTracks().forEach((track) => _peerConnection!.addTrack(track, _localStream!));

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams[0];
        onRemoteStream?.call();
      }
    };

    _peerConnection!.onIceCandidate = (candidate) {
      // MATCHING IMAGE: call:ice-candidate
      SocketService.instance.socket?.emit('call:ice-candidate', {
        'candidate': candidate.toMap(),
        'to': 'RECEIVER_ID', // You'll need the target user ID here
      });
    };

    SocketService.instance.getSocketConnection();
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    final socket = SocketService.instance.socket;

    socket?.on(KeyConst.callRinging, (data) async {
      Logger().i("Call is ringing... $data");
      statusString = "Ringing...";
      onStatusUpdate?.call();
    });

    // MATCHING IMAGE: Listen for incoming call
    socket?.on(KeyConst.callIncoming, (data) async {
      Logger().i("Incoming call from: $data");
      statusString = "Incoming call from data";
      onStatusUpdate?.call();
      ringingCall(data['callId']);
      Future.delayed(Duration(seconds: 2), () {
        acceptCall(data['callId']);
      });
    });

    // MATCHING IMAGE: Listen for accepted call to start WebRTC
    socket?.on(KeyConst.callAccepted, (data) async {
      Logger().i("Call accepted by remote. ${data} Creating offer...");
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
        Logger().i(description.toMap());
        if (_peerConnection!.signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          await _peerConnection!.setRemoteDescription(description);
        } else {
          Logger().w("Ignoring answer: signaling state is ${_peerConnection!.signalingState}");
          return;
        }

        for (var candidate in candidateQueue) {
          await _peerConnection!.addCandidate(candidate);
        }
        candidateQueue.clear();
        Logger().i(data);
        callId = data['callId'];
        statusString = "Call established";
        onStatusUpdate?.call();
      } on Exception catch (e) {
        Logger().e("Error setting remote description: $e");
      }
    });

    socket?.on(KeyConst.callEnded, (data) async {
      Logger().i("Call ended by remote.");
      statusString = "Call ended";
      onStatusUpdate?.call();
      await _peerConnection?.close();
      _peerConnection = null;
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
  void initiateCall(String targetUserId) {
    Logger().i("Initiating call to: $targetUserId");
    statusString = "Calling $targetUserId";
    onStatusUpdate?.call();
    SocketService.instance.socket?.emit('call:initiate', {'calleeId': targetUserId});
  }

  void ringingCall(String callerId) {
    Logger().i("Ringing call for: $callerId");
    statusString = "Ringing...";
    onStatusUpdate?.call();
    SocketService.instance.socket?.emit(KeyConst.callRinging, {'callId': callerId});
  }

  // MATCHING IMAGE: Accept Call
  void acceptCall(String callId) {
    Logger().i("Accepting call: $callId");
    statusString = "Accepting call...";
    onStatusUpdate?.call();
    SocketService.instance.socket?.emit(KeyConst.callAccept, {'callId': callId});
  }

  Future<void> _makeOffer(String callId) async {
    statusString = "Creating call offer...";
    onStatusUpdate?.call();

    Map<String, dynamic> constraints = {
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
      'optional': [],
    };

    RTCSessionDescription offer = await _peerConnection!.createOffer(constraints);
    await _peerConnection!.setLocalDescription(offer);
    Logger().i(offer.toMap());
    SocketService.instance.socket?.emit(KeyConst.callOffer, {"callId": callId, "sdp": offer.sdp, "type": offer.type});

    _peerConnection?.onIceCandidate = (candidate) {
      SocketService.instance.socket?.emit(KeyConst.callIceCandidate, {'candidate': candidate.toMap(), 'callId': callId});
    };
  }

  Future<void> _makeAnswer(String callId) async {
    statusString = "Creating call answer...";
    onStatusUpdate?.call();

    Map<String, dynamic> constraints = {
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
      'optional': [],
    };
    RTCSessionDescription answer = await _peerConnection!.createAnswer(constraints);
    await _peerConnection!.setLocalDescription(answer);
    SocketService.instance.socket?.emit(KeyConst.callAnswer, {"callId": callId, "sdp": answer.sdp, "type": answer.type});
  }

  Future<void> endCall() async {
    statusString = "Ending call...";
    onStatusUpdate?.call();
    Logger().i("Ending call: $callId");
    SocketService.instance.socket?.emit(KeyConst.callEnd, {'callId': callId});

    _timer.cancel();
    timeString = "";
    onTimerUpdate?.call();
    statusString = "Call ended";
    onStatusUpdate?.call();
  }

  void startCallTimer(int startTimeStamp) {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final duration = Duration(milliseconds: now - startTimeStamp);
 

      timeString = "${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}";
      onTimerUpdate?.call();
    });
  }
}
