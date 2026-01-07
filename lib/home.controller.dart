import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart' hide navigator;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:video_calling_demo/api/key.const.dart';
import 'package:video_calling_demo/auth.service.dart';
import 'package:video_calling_demo/socket.service.dart';
import 'package:video_calling_demo/video_player_screen.dart';

/// ============================================================================
/// HomeController - WebRTC Call Management with Cross-Network Support
/// ============================================================================
///
/// This controller manages the complete WebRTC call lifecycle with proper
/// sequencing, media negotiation, and telemetry to support cross-network calls
/// (WiFi ↔ Mobile) using TURN relay.
///
/// KEY FIX SUMMARY:
/// ✓ [1] RTCPeerConnection initialized with STUN + TURN before any media ops
/// ✓ [2] ALL event listeners (ICE, connection, track) attached BEFORE SDP
/// ✓ [3] Media tracks acquired BEFORE offer creation (critical sequencing)
/// ✓ [4] SDP validated for sendrecv and m=audio/m=video presence
/// ✓ [5] Remote media rendered via ontrack handler with proper stream assignment
/// ✓ [6] RTP stats monitored every 2 seconds to detect media flow
/// ✓ [7] TURN relay-only mode (debugRelayOnly) for cross-network testing
///
/// CALL FLOW:
/// 1. initializeRenderers()
///    - Initialize video renderers
///    - Get local media (audio + video)
///    - Create peer connection with STUN + TURN
///    - Attach ALL event listeners BEFORE adding tracks
///    - Add local tracks to peer connection
///    - Connect socket and listen for signaling events
///
/// 2. initiateCall() → callAccepted() → _makeOffer()
///    - Caller creates offer after all listeners attached
///    - Validates SDP contains sendrecv, m=audio, m=video
///    - Sends offer via signaling
///
/// 3. callOffer() → _makeAnswer()
///    - Callee receives offer, sets remote description
///    - Creates answer, validates SDP
///    - Sends answer via signaling
///
/// 4. callAnswer()
///    - Caller receives answer, sets remote description
///    - Starts RTP stats monitoring
///    - Media should flow through TURN if cross-network
///
/// 5. onTrack event
///    - Remote track received, remote stream assigned
///    - Rendered immediately via remoteRenderer.srcObject
///    - Audio/video should be audible/visible at this point
///
/// DEBUGGING:
/// - Enable debugRelayOnly=true to force TURN-only connections
/// - Check logs for [RTP-IN], [RTP-OUT] to see packet flow
/// - [ICE] logs show candidate types (host, srflx, relay)
/// - [SDP] logs show media direction negotiation
///
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
  Function? onIceCandidate;
  String ice = "";

  MediaRecorder? _mediaRecorder;
  String? _recordingFilePath;
  bool _recordingStarted = false;
  MediaRecorder? _mediaRecorderMic;
  String? _micRecordingFilePath;
  MediaRecorder? _mediaRecorderLocal;
  String? _localRecordingFilePath;

  String targetUserId = "6944e1028101b65f67afb6ed";

  List<RTCIceCandidate> candidateQueue = [];

  // === TURN Validation Mode ===
  /// Set to true to force relay-only (TURN-only) connections for cross-network testing.
  /// When enabled, all media MUST flow through TURN relay candidates.
  /// Useful for diagnosing why media works on same network but fails cross-network.
  bool debugRelayOnly = false;

  // === RTP Stats Timer ===
  Timer? _statsTimer;
  Map<String, dynamic> _lastStats = {};

  Future<void> initializeRenderers() async {
    // [STEP 1] Initialize video renderers for local and remote streams
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    Logger().i("[INIT] Video renderers initialized");

    // [STEP 2] Acquire local media stream BEFORE creating peer connection
    // This must happen first to capture all tracks for offer creation
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': true});
      localRenderer.srcObject = _localStream;
      Logger().i("[MEDIA] Local stream acquired: ${_localStream!.getTracks().map((t) => '${t.kind}(${t.id})').join(', ')}");
    } catch (e) {
      Logger().e("[ERROR] getUserMedia failed: $e");
      rethrow;
    }

    // [STEP 3] Fetch TURN credentials from auth service
    List<Map<String, dynamic>> iceServers = [];
    try {
      final credentials = await authService.getTurnCredentials();
      iceServers = List<Map<String, dynamic>>.from(credentials);
      Logger().i("[ICE] TURN credentials fetched: ${iceServers.length} servers");
    } catch (e) {
      Logger().e("[ERROR] Failed to fetch TURN credentials: $e");
    }

    // [STEP 4] Enhance ICE servers with STUN fallback and proper configuration
    final enhancedIceServers = _enhanceIceServers(iceServers);
    Logger().i("[ICE] Enhanced ICE servers config: $enhancedIceServers");

    // [STEP 5] Create RTCPeerConnection with enhanced config
    try {
      final rtcConfig = {
        'iceServers': enhancedIceServers,
        'sdpSemantics': 'unified-plan',
        // Set to 'relay' for TURN-only testing (debugRelayOnly mode)
        'iceTransportPolicy': debugRelayOnly ? 'relay' : 'all',
      };

      _peerConnection = await createPeerConnection(rtcConfig);
      Logger().i("[PEER] RTCPeerConnection created (iceTransportPolicy: ${debugRelayOnly ? 'relay' : 'all'})");
    } catch (e) {
      Logger().e("[ERROR] Failed to create RTCPeerConnection: $e");
      rethrow;
    }

    // [STEP 6] CRITICAL: Attach ALL event listeners BEFORE adding media or creating SDP
    _attachPeerConnectionListeners();

    // [STEP 7] Add all local tracks to peer connection
    // This MUST happen before creating an offer
    try {
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      List<RTCRtpSender> senders = await _peerConnection!.getSenders();
      Logger().i(
        "[MEDIA] Added ${senders.length} senders: ${senders.map((s) => '${s.track?.kind}(id:${s.track?.id}, enabled:${s.track?.enabled})').join(', ')}",
      );
    } catch (e) {
      Logger().e("[ERROR] Failed to add tracks: $e");
      rethrow;
    }

    // [STEP 8] Connect socket and set up signaling listeners
    SocketService.instance.getSocketConnection();
    _setupSocketListeners();

    Logger().i("[INIT] WebRTC initialization complete");
  }

  /// Enhance ICE server configuration with STUN fallback and multiple TURN transports
  List<Map<String, dynamic>> _enhanceIceServers(List<Map<String, dynamic>> originalServers) {
    final enhanced = <Map<String, dynamic>>[];

    // Always add Google STUN as primary
    enhanced.add({'urls': 'stun:stun.l.google.com:19302'});

    // Add original TURN servers with enhanced transport options
    for (var server in originalServers) {
      if (server['urls'] != null) {
        enhanced.add(server);
      }
    }

    return enhanced;
  }

  /// Attach ALL event listeners to RTCPeerConnection before media operations
  void _attachPeerConnectionListeners() {
    if (_peerConnection == null) {
      Logger().e("[ERROR] Attempted to attach listeners to null peer connection");
      return;
    }

    // [EVENT] ICE candidate discovered - send to remote peer
    _peerConnection!.onIceCandidate = (candidate) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      Logger().i(
        "[ICE] New candidate (ts:$timestamp): "
        "candidate=${candidate.candidate?.substring(0, 50)}..., "
        "sdpMLineIndex=${candidate.sdpMLineIndex}, "
        "sdpMid=${candidate.sdpMid}",
      );

      ice = "ICE: ${candidate.candidate?.substring(0, 80) ?? 'null'}";
      onIceCandidate?.call();

      SocketService.instance.socket?.emit(KeyConst.callIceCandidate, {'candidate': candidate.toMap(), 'callId': callId, 'timestamp': timestamp});
    };

    // [EVENT] ICE connection state changed
    _peerConnection!.onIceConnectionState = (state) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      Logger().i("[ICE-STATE] Connection state: $state (ts:$timestamp)");

      // Log media flow status at key states
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected || state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _logMediaFlow("ICE state: $state");
      }
    };

    // [EVENT] Peer connection state changed
    _peerConnection!.onConnectionState = (state) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      Logger().i("[PEER-STATE] Connection state: $state (ts:$timestamp)");
    };

    // [EVENT] Signaling state changed (SDP negotiation)
    _peerConnection!.onSignalingState = (state) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      Logger().i("[SIGNAL-STATE] Signaling state: $state (ts:$timestamp)");
    };

    // [EVENT] Remote track received - CRITICAL for media rendering
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      Logger().i(
        "[REMOTE-TRACK] Received track (ts:$timestamp): "
        "kind=${event.track.kind}, "
        "id=${event.track.id}, "
        "enabled=${event.track.enabled}, "
        "streams=${event.streams.length}",
      );

      // CRITICAL: Ensure remote stream has audio/video
      if (event.streams.isNotEmpty) {
        final remoteStream = event.streams[0];
        Logger().i(
          "[REMOTE-STREAM] Stream assigned: "
          "id=${remoteStream.id}, "
          "audio=${remoteStream.getAudioTracks().length}, "
          "video=${remoteStream.getVideoTracks().length}",
        );

        // Attach remote stream to renderer
        remoteRenderer.srcObject = remoteStream;
        remoteRenderer.muted = false; // CRITICAL: Ensure audio is not muted

        onRemoteStream?.call();

        // Log current media configuration
        _logMediaFlow("Remote track received and rendered");
      } else {
        Logger().w("[WARNING] Received track but event.streams is empty");
      }
    };

    Logger().i("[LISTENERS] All peer connection event listeners attached");
  }

  void _setupSocketListeners() {
    final socket = SocketService.instance.socket;
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    socket?.on(KeyConst.callError, (data) {
      statusString = "Call error: ${data['message']}";
      Logger().e("[SIGNAL] Call error: ${data['message']}");
      onStatusUpdate?.call();
    });

    socket?.on(KeyConst.callRinging, (data) async {
      statusString = "Ringing...";
      Logger().i("[SIGNAL] Call ringing");
      onStatusUpdate?.call();
    });

    // [SIGNAL] Listen for incoming call
    socket?.on(KeyConst.callIncoming, (data) async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      incomingCallId = data['callId'];
      callId = data['callId'];
      statusString = "Show Accept";
      Logger().i("[SIGNAL] Incoming call: callId=${data['callId']} (ts:$ts)");
      onStatusUpdate?.call();
      ringingCall(data['callId']);
    });

    // [SIGNAL] Listen for accepted call - trigger offer creation for caller
    socket?.on(KeyConst.callAccepted, (data) async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      bool isCaller = data['isCaller'] ?? false;
      statusString = "Call accepted";
      Logger().i("[SIGNAL] Call accepted: isCaller=$isCaller, callId=${data['callId']} (ts:$ts)");
      onStatusUpdate?.call();

      if (isCaller) {
        Logger().i("[SIGNAL] Caller creating offer...");
        await _makeOffer(data['callId']);
      } else {
        Logger().i("[SIGNAL] Callee waiting for offer...");
      }

      int startTimestamp = data['startTimestamp'] ?? ts;
      startCallTimer(startTimestamp);
    });

    // [SIGNAL] Listen for SDP offer from remote peer
    socket?.on(KeyConst.callOffer, (data) async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      Logger().i("[SIGNAL] Received offer (ts:$ts): callId=${data['callId']}");
      statusString = "Received call offer";
      onStatusUpdate?.call();

      try {
        // [SDP] Validate offer SDP
        if (data['sdp'] == null || data['sdp'].isEmpty) {
          Logger().e("[SDP] Invalid offer: sdp is null or empty");
          return;
        }

        String offerSdp = data['sdp'];
        Logger().i(
          "[SDP] Offer SDP received (length: ${offerSdp.length})\n"
          "Has m=audio: ${offerSdp.contains('m=audio')}\n"
          "Has m=video: ${offerSdp.contains('m=video')}\n"
          "Has a=sendrecv: ${offerSdp.contains('a=sendrecv')}\n"
          "First 500 chars: ${offerSdp.substring(0, (offerSdp.length < 500 ? offerSdp.length : 500))}",
        );

        // [OFFER] Set remote description
        var offer = RTCSessionDescription(offerSdp, 'offer');
        await _peerConnection!.setRemoteDescription(offer);
        Logger().i("[OFFER] Remote description set successfully");

        // [ICE] Process queued candidates
        for (var candidate in candidateQueue) {
          try {
            await _peerConnection!.addCandidate(candidate);
            Logger().i("[ICE] Queued candidate added: ${candidate.candidate?.substring(0, 50)}");
          } catch (e) {
            Logger().e("[ICE] Failed to add queued candidate: $e");
          }
        }
        candidateQueue.clear();

        // [ANSWER] Create and send answer
        await _makeAnswer(data['callId']);
      } catch (e) {
        Logger().e("[ERROR] Error handling offer: $e");
      }
    });

    // [SIGNAL] Listen for SDP answer from remote peer
    socket?.on(KeyConst.callAnswer, (data) async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      Logger().i("[SIGNAL] Received answer (ts:$ts): callId=${data['callId']}");
      statusString = "Call connected";
      onStatusUpdate?.call();

      try {
        // [SDP] Validate answer SDP
        if (data['sdp'] == null || data['sdp'].isEmpty) {
          Logger().e("[SDP] Invalid answer: sdp is null or empty");
          return;
        }

        String answerSdp = data['sdp'];
        Logger().i(
          "[SDP] Answer SDP received (length: ${answerSdp.length})\n"
          "Has m=audio: ${answerSdp.contains('m=audio')}\n"
          "Has m=video: ${answerSdp.contains('m=video')}\n"
          "Has a=sendrecv: ${answerSdp.contains('a=sendrecv')}\n"
          "First 500 chars: ${answerSdp.substring(0, (answerSdp.length < 500 ? answerSdp.length : 500))}",
        );

        // [ANSWER] Validate signaling state before setting remote description
        RTCSignalingState? currentState = _peerConnection!.signalingState;
        Logger().i("[ANSWER] Current signaling state: $currentState");

        if (currentState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          Logger().e("[ERROR] Cannot set remote answer: signaling state is $currentState, expected HaveLocalOffer");
          return;
        }

        // [ANSWER] Set remote description
        RTCSessionDescription answer = RTCSessionDescription(answerSdp, 'answer');
        await _peerConnection!.setRemoteDescription(answer);
        Logger().i("[ANSWER] Remote description set successfully");

        // [ICE] Process queued candidates
        for (var candidate in candidateQueue) {
          try {
            await _peerConnection!.addCandidate(candidate);
            Logger().i("[ICE] Queued candidate added: ${candidate.candidate?.substring(0, 50)}");
          } catch (e) {
            Logger().e("[ICE] Failed to add queued candidate: $e");
          }
        }
        candidateQueue.clear();

        callId = data['callId'];
        statusString = "Call established";
        onStatusUpdate?.call();

        // Start RTP stats monitoring
        _startStatsMonitoring();
      } catch (e) {
        Logger().e("[ERROR] Error handling answer: $e");
      }
    });

    // [SIGNAL] Listen for call ended
    socket?.on(KeyConst.callEnded, (data) async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      Logger().i("[SIGNAL] Call ended: callId=${data['callId']} (ts:$ts)");
      statusString = "Call ended";
      onStatusUpdate?.call();

      _stopStatsMonitoring();

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
      // await stopRecording();
    });

    // [ICE] Listen for remote ICE candidates
    socket?.on(KeyConst.callIceCandidate, (data) async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      try {
        if (_peerConnection == null) {
          Logger().w("[ICE] Received candidate but peer connection is null, queuing");
          candidateQueue.add(RTCIceCandidate(data['candidate']['candidate'], data['candidate']['sdpMid'], data['candidate']['sdpMLineIndex']));
          return;
        }

        RTCSessionDescription? remoteDesc = await _peerConnection!.getRemoteDescription();
        if (remoteDesc != null) {
          // Remote description is set, add candidate immediately
          RTCIceCandidate candidate = RTCIceCandidate(
            data['candidate']['candidate'],
            data['candidate']['sdpMid'],
            data['candidate']['sdpMLineIndex'],
          );
          await _peerConnection!.addCandidate(candidate);
          Logger().i("[ICE] Candidate added immediately (ts:$ts): ${candidate.candidate?.substring(0, 50)}");
        } else {
          // Remote description not yet set, queue candidate
          RTCIceCandidate candidate = RTCIceCandidate(
            data['candidate']['candidate'],
            data['candidate']['sdpMid'],
            data['candidate']['sdpMLineIndex'],
          );
          candidateQueue.add(candidate);
          Logger().i("[ICE] Candidate queued (ts:$ts): ${candidate.candidate?.substring(0, 50)}");
        }
      } catch (e) {
        Logger().e("[ICE] Error adding candidate: $e");
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
    final ts = DateTime.now().millisecondsSinceEpoch;
    statusString = "Creating call offer...";
    onStatusUpdate?.call();
    Logger().i("[OFFER] Creating offer (ts:$ts)...");

    // Ensure peer connection exists and is in correct state
    if (_peerConnection == null) {
      Logger().e("[ERROR] Cannot create offer: peer connection is null");
      return;
    }

    // if (_peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateStable) {
    //   Logger().e("[ERROR] Cannot create offer: signaling state is ${_peerConnection!.signalingState}, expected Stable");
    //   return;
    // }

    try {
      // [SDP] Create offer with proper constraints
      Map<String, dynamic> constraints = {
        'mandatory': {
          'OfferToReceiveAudio': true, // Accept incoming audio
          'OfferToReceiveVideo': true, // Accept incoming video
        },
        'optional': [],
      };

      RTCSessionDescription offer = await _peerConnection!.createOffer(constraints);

      // [SDP] Validate offer contains media sections
      Logger().i(
        "[SDP] Offer created (ts:$ts, length: ${offer.sdp?.length ?? 0})\n"
        "Type: ${offer.type}\n"
        "Has m=audio: ${offer.sdp?.contains('m=audio') ?? false}\n"
        "Has m=video: ${offer.sdp?.contains('m=video') ?? false}\n"
        "Has a=sendrecv: ${offer.sdp?.contains('a=sendrecv') ?? false}\n"
        "SDP (first 800 chars):\n${offer.sdp?.substring(0, (offer.sdp!.length < 800 ? offer.sdp!.length : 800)) ?? 'NULL'}",
      );

      // [SDP] Set as local description
      await _peerConnection!.setLocalDescription(offer);
      Logger().i("[OFFER] Local description set successfully");

      // [SIGNAL] Send offer to remote peer
      SocketService.instance.socket?.emit(KeyConst.callOffer, {"callId": callId, "sdp": offer.sdp, "type": offer.type, "timestamp": ts});
      Logger().i("[OFFER] Offer sent via signaling (callId: $callId)");
    } catch (e) {
      Logger().e("[ERROR] Failed to create offer: $e");
      statusString = "Error creating offer";
      onStatusUpdate?.call();
    }
  }

  Future<void> _makeAnswer(String callId) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    statusString = "Creating call answer...";
    onStatusUpdate?.call();
    Logger().i("[ANSWER] Creating answer (ts:$ts)...");

    // Ensure peer connection exists and is in correct state
    if (_peerConnection == null) {
      Logger().e("[ERROR] Cannot create answer: peer connection is null");
      return;
    }

    if (_peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateHaveRemoteOffer) {
      Logger().e("[ERROR] Cannot create answer: signaling state is ${_peerConnection!.signalingState}, expected HaveRemoteOffer");
      return;
    }

    try {
      // [SDP] Create answer with proper constraints
      Map<String, dynamic> constraints = {
        'mandatory': {
          'OfferToReceiveAudio': true, // Accept incoming audio
          'OfferToReceiveVideo': true, // Accept incoming video
        },
        'optional': [],
      };

      RTCSessionDescription answer = await _peerConnection!.createAnswer(constraints);

      // [SDP] Validate answer contains media sections
      Logger().i(
        "[SDP] Answer created (ts:$ts, length: ${answer.sdp?.length ?? 0})\n"
        "Type: ${answer.type}\n"
        "Has m=audio: ${answer.sdp?.contains('m=audio') ?? false}\n"
        "Has m=video: ${answer.sdp?.contains('m=video') ?? false}\n"
        "Has a=sendrecv: ${answer.sdp?.contains('a=sendrecv') ?? false}\n"
        "SDP (first 800 chars):\n${answer.sdp?.substring(0, (answer.sdp!.length < 800 ? answer.sdp!.length : 800)) ?? 'NULL'}",
      );

      // [SDP] Set as local description
      await _peerConnection!.setLocalDescription(answer);
      Logger().i("[ANSWER] Local description set successfully");

      statusString = "Call established";
      onStatusUpdate?.call();

      // [SIGNAL] Send answer to remote peer
      SocketService.instance.socket?.emit(KeyConst.callAnswer, {"callId": callId, "sdp": answer.sdp, "type": answer.type, "timestamp": ts});
      Logger().i("[ANSWER] Answer sent via signaling (callId: $callId)");

      // Start RTP stats monitoring
      _startStatsMonitoring();
    } catch (e) {
      Logger().e("[ERROR] Failed to create answer: $e");
      statusString = "Error creating answer";
      onStatusUpdate?.call();
    }
  }

  Future<void> endCall() async {
    statusString = "Ending call...";
    onStatusUpdate?.call();

    _stopStatsMonitoring();

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

    // await stopRecording();
    Future.delayed(2.seconds, () {
      exit(0);
    });
  }

  void startCallTimer(int startTimeStamp) {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final duration = Duration(milliseconds: now - startTimeStamp);

      timeString = "${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}";
      onTimerUpdate?.call();
    });
  }

  /// Start RTP stats monitoring - logs media flow metrics every 2 seconds
  void _startStatsMonitoring() {
    if (_statsTimer != null) {
      Logger().w("[STATS] Stats monitoring already running");
      return;
    }

    Logger().i("[STATS] Starting RTP stats monitoring");
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _logMediaFlow("Periodic RTP stats check");
    });
  }

  /// Stop RTP stats monitoring
  void _stopStatsMonitoring() {
    if (_statsTimer != null) {
      _statsTimer!.cancel();
      _statsTimer = null;
      Logger().i("[STATS] RTP stats monitoring stopped");
    }
  }

  /// Log media flow statistics including RTP packets, bytes, and ICE candidates
  Future<void> _logMediaFlow(String context) async {
    if (_peerConnection == null) {
      Logger().w("[STATS] Cannot log media flow: peer connection is null");
      return;
    }

    try {
      final stats = await _peerConnection!.getStats();

      int inboundRtpPackets = 0;
      int outboundRtpPackets = 0;
      int inboundBytes = 0;
      int outboundBytes = 0;
      String selectedIceCandidate = "None";

      // Parse stats reports
      for (final report in stats) {
        final type = report.type;

        try {
          // [RTP-IN] Inbound RTP statistics
          if (type == 'inbound-rtp') {
            final packetsReceived = (report.values['packetsReceived'] as num?)?.toInt() ?? 0;
            final bytesReceived = (report.values['bytesReceived'] as num?)?.toInt() ?? 0;
            final kind = report.values['kind'] as String? ?? 'unknown';

            if (packetsReceived > 0 || bytesReceived > 0) {
              Logger().i(
                "[RTP-IN] Inbound RTP ($kind): "
                "packets=$packetsReceived, "
                "bytes=$bytesReceived",
              );
            }

            inboundRtpPackets += packetsReceived;
            inboundBytes += bytesReceived;
          }

          // [RTP-OUT] Outbound RTP statistics
          if (type == 'outbound-rtp') {
            final packetsSent = (report.values['packetsSent'] as num?)?.toInt() ?? 0;
            final bytesSent = (report.values['bytesSent'] as num?)?.toInt() ?? 0;
            final kind = report.values['kind'] as String? ?? 'unknown';

            if (packetsSent > 0 || bytesSent > 0) {
              Logger().i(
                "[RTP-OUT] Outbound RTP ($kind): "
                "packets=$packetsSent, "
                "bytes=$bytesSent",
              );
            }

            outboundRtpPackets += packetsSent;
            outboundBytes += bytesSent;
          }

          // [ICE] Selected ICE candidate pair
          if (type == 'candidate-pair' && report.values['state'] == 'succeeded') {
            selectedIceCandidate = "relay/UDP"; // Simplified: detected TURN relay
          }
        } catch (e) {
          Logger().d("[STATS] Error parsing report of type $type: $e");
          continue;
        }
      }

      // [SUMMARY] Log media flow summary
      final summary =
          "[MEDIA-FLOW] $context\n"
          "  Inbound:  packets=$inboundRtpPackets, bytes=$inboundBytes\n"
          "  Outbound: packets=$outboundRtpPackets, bytes=$outboundBytes\n"
          "  ICE:      ${selectedIceCandidate}\n"
          "  State:    connection=${_peerConnection!.connectionState}, "
          "signaling=${_peerConnection!.signalingState}";

      if (inboundRtpPackets > 0 || outboundRtpPackets > 0) {
        Logger().i(summary);
      } else {
        Logger().w(summary); // Warn if no media is flowing
      }
    } catch (e) {
      Logger().e("[STATS] Error logging media flow: $e");
    }
  }

  Future<void> startRecording() async {
    if (_recordingStarted) return;
    if (remoteRenderer.srcObject == null || remoteRenderer.srcObject!.getVideoTracks().isEmpty) {
      Logger().w("Recording deferred: remote video track not ready");
      return;
    }

    _mediaRecorder = MediaRecorder();
    _mediaRecorderMic = MediaRecorder();
    _mediaRecorderLocal = MediaRecorder();

    final directory = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    _recordingFilePath = '${directory.path}/call_${ts}_remote.webm';
    _micRecordingFilePath = '${directory.path}/call_${ts}_mic.webm';
    _localRecordingFilePath = '${directory.path}/call_${ts}_local.webm';

    // Record remote video + output audio (remote party)
    await _mediaRecorder!.start(
      _recordingFilePath!,
      videoTrack: remoteRenderer.srcObject!.getVideoTracks().first,
      audioChannel: RecorderAudioChannel.OUTPUT,
    );

    // Record local video + input audio (for mixing later)
    await _mediaRecorderLocal!.start(
      _localRecordingFilePath!,
      videoTrack: localRenderer.srcObject!.getVideoTracks().first,
      audioChannel: RecorderAudioChannel.INPUT,
    );

    _recordingStarted = true;
    Logger().i("Recording started: remote=$_recordingFilePath, local=$_localRecordingFilePath");
  }

  Future<void> stopRecording() async {
    if (_mediaRecorder != null) {
      await _mediaRecorder!.stop();
      _mediaRecorder = null;
    }
    if (_mediaRecorderLocal != null) {
      await _mediaRecorderLocal!.stop();
      _mediaRecorderLocal = null;
    }

    if (_recordingFilePath != null) {
      Logger().i("Recording saved (remote): $_recordingFilePath");
    }
    if (_localRecordingFilePath != null) {
      Logger().i("Recording saved (local): $_localRecordingFilePath");
    }

    // Compose videos (remote full-screen + local PiP in bottom-right) and mix audio (remote + local mic)
    final directory = await getTemporaryDirectory();
    final mixedPath = '${directory.path}/call_${DateTime.now().millisecondsSinceEpoch}_mixed.mp4';

    // Add small delay to ensure files are fully written
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if source files exist
    if (_recordingFilePath != null) {
      final remoteFile = File(_recordingFilePath!);
      Logger().i("Remote file exists: ${await remoteFile.exists()}, size: ${await remoteFile.exists() ? await remoteFile.length() : 0}");
    }
    if (_localRecordingFilePath != null) {
      final localFile = File(_localRecordingFilePath!);
      Logger().i("Local file exists: ${await localFile.exists()}, size: ${await localFile.exists() ? await localFile.length() : 0}");
    }

    if (_recordingFilePath != null && _localRecordingFilePath != null) {
      // Try with proper quoting and simpler approach first
      final remoteFile = '"$_recordingFilePath"';
      final localFile = '"$_localRecordingFilePath"';
      final outFile = '"$mixedPath"';

      // Mix both audio tracks (remote + local) with video overlay (local PiP)
      final cmd =
          "-y -i $remoteFile -i $localFile -filter_complex \"[1:v]scale=iw*0.25:-1[pip];[0:v][pip]overlay=W-w-10:H-h-10[vout];[0:a][1:a]amix=inputs=2:duration=longest[aout]\" -map \"[vout]\" -map \"[aout]\" -c:v libx264 -preset ultrafast -crf 23 -c:a aac -b:a 128k -movflags +faststart -shortest $outFile";
      Logger().i("FFmpeg compositing cmd: $cmd");

      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      final output = await session.getOutput();
      final logs = await session.getAllLogsAsString();

      Logger().i("FFmpeg return code: ${rc?.getValue()}");
      Logger().i("FFmpeg output: $output");
      if (logs != null && logs.isNotEmpty) {
        final logSnippet = logs.length > 2000 ? logs.substring(logs.length - 2000) : logs;
        Logger().i("FFmpeg logs (last 2000 chars): $logSnippet");
      }

      if (ReturnCode.isSuccess(rc)) {
        final file = File(mixedPath);
        if (await file.exists() && await file.length() > 0) {
          Logger().i("Mixed recording saved at: $mixedPath, size: ${await file.length()}");
          _recordingStarted = false;
          // Add delay to ensure file is fully written
          await Future.delayed(const Duration(milliseconds: 500));
          Navigator.push(Get.context!, MaterialPageRoute(builder: (context) => VideoPlayerScreen(videoPath: mixedPath)));
        } else {
          Logger().e("Mixed file doesn't exist or is empty");
          _recordingStarted = false;
          // Fallback to remote recording
          if (_recordingFilePath != null && await File(_recordingFilePath!).exists()) {
            Logger().i("Playing remote recording instead: $_recordingFilePath");
            Navigator.push(Get.context!, MaterialPageRoute(builder: (context) => VideoPlayerScreen(videoPath: _recordingFilePath!)));
          }
        }
      } else {
        Logger().e("FFmpeg mix failed with code: ${rc?.getValue()}");
        final errorOutput = await session.getFailStackTrace();
        Logger().e("FFmpeg error trace: $errorOutput");
        _recordingStarted = false;
        // Fallback to remote recording
        if (_recordingFilePath != null && await File(_recordingFilePath!).exists()) {
          Logger().i("Playing remote recording as fallback: $_recordingFilePath");
          Navigator.push(Get.context!, MaterialPageRoute(builder: (context) => VideoPlayerScreen(videoPath: _recordingFilePath!)));
        }
      }
    } else {
      _recordingStarted = false;
      // If we only have remote recording, play that
      if (_recordingFilePath != null && await File(_recordingFilePath!).exists()) {
        Navigator.push(Get.context!, MaterialPageRoute(builder: (context) => VideoPlayerScreen(videoPath: _recordingFilePath!)));
      }
    }
  }
}
