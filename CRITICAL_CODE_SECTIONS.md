# Critical Code Sections - Copy/Reference

This file contains the most critical code sections for easy reference and understanding.

---

## Critical Section 1: Event Listener Attachment

**FILE:** lib/home.controller.dart  
**METHOD:** _attachPeerConnectionListeners()  
**CRITICAL:** Must be called BEFORE adding tracks

```dart
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
    
    SocketService.instance.socket?.emit(
      KeyConst.callIceCandidate,
      {'candidate': candidate.toMap(), 'callId': callId, 'timestamp': timestamp},
    );
  };

  // [EVENT] ICE connection state changed
  _peerConnection!.onIceConnectionState = (state) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    Logger().i("[ICE-STATE] Connection state: $state (ts:$timestamp)");
    
    // Log media flow status at key states
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
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
```

---

## Critical Section 2: Remote Media Rendering

**FILE:** lib/home.controller.dart  
**LOCATION:** onTrack event handler (above)  
**CRITICAL:** These 3 lines are essential for audio/video to work

```dart
// CRITICAL: Assign stream directly to renderer
remoteRenderer.srcObject = remoteStream;

// CRITICAL: Ensure audio is not muted (many calls fail here!)
remoteRenderer.muted = false;

// Notify UI that media is ready
onRemoteStream?.call();
```

**Why Each Line Matters:**
- `remoteRenderer.srcObject = remoteStream` - Connects the media stream to the UI widget
- `remoteRenderer.muted = false` - Enables audio playback (CRITICAL: default is true!)
- `onRemoteStream?.call()` - Triggers UI rebuild to show video

---

## Critical Section 3: Initialization Sequence

**FILE:** lib/home.controller.dart  
**METHOD:** initializeRenderers()  
**CRITICAL:** EXACT sequence required, any changes break it

```dart
Future<void> initializeRenderers() async {
  // [STEP 1] Initialize video renderers for local and remote streams
  await localRenderer.initialize();
  await remoteRenderer.initialize();
  Logger().i("[INIT] Video renderers initialized");

  // [STEP 2] Acquire local media stream BEFORE creating peer connection
  // This must happen first to capture all tracks for offer creation
  try {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': true
    });
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
```

**The Sequence (CANNOT be changed):**
1. Initialize renderers
2. Get media (getUserMedia)
3. Fetch TURN
4. Enhance ICE
5. Create peer connection
6. **Attach listeners** ← CRITICAL: must be before step 7
7. Add tracks
8. Setup signaling

---

## Critical Section 4: SDP Creation and Validation

**FILE:** lib/home.controller.dart  
**METHOD:** _makeOffer()  
**CRITICAL:** Validates SDP has required media sections

```dart
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

  if (_peerConnection!.signalingState != RTCSignalingState.RTCSignalingStateStable) {
    Logger().e("[ERROR] Cannot create offer: signaling state is ${_peerConnection!.signalingState}, expected Stable");
    return;
  }

  try {
    // [SDP] Create offer with proper constraints
    Map<String, dynamic> constraints = {
      'mandatory': {
        'OfferToReceiveAudio': true,  // Accept incoming audio
        'OfferToReceiveVideo': true   // Accept incoming video
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
      "SDP (first 800 chars):\n${offer.sdp?.substring(0, (offer.sdp!.length < 800 ? offer.sdp!.length : 800)) ?? 'NULL'}"
    );

    // [SDP] Set as local description
    await _peerConnection!.setLocalDescription(offer);
    Logger().i("[OFFER] Local description set successfully");

    // [SIGNAL] Send offer to remote peer
    SocketService.instance.socket?.emit(
      KeyConst.callOffer,
      {
        "callId": callId,
        "sdp": offer.sdp,
        "type": offer.type,
        "timestamp": ts
      },
    );
    Logger().i("[OFFER] Offer sent via signaling (callId: $callId)");

  } catch (e) {
    Logger().e("[ERROR] Failed to create offer: $e");
    statusString = "Error creating offer";
    onStatusUpdate?.call();
  }
}
```

**What to Check in Logs:**
```
[SDP] Offer created
Has m=audio: true        ← MUST be true
Has m=video: true        ← MUST be true
Has a=sendrecv: true     ← MUST be true
```

---

## Critical Section 5: RTP Stats Monitoring

**FILE:** lib/home.controller.dart  
**METHOD:** _logMediaFlow()  
**CRITICAL:** This tells you if media is actually flowing

```dart
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
      final reportData = report.toMap();
      final type = reportData['type'] as String?;
      
      // [RTP-IN] Inbound RTP statistics
      if (type == 'inbound-rtp') {
        final packetsReceived = reportData['packetsReceived'] as int? ?? 0;
        final bytesReceived = reportData['bytesReceived'] as int? ?? 0;
        final kind = reportData['kind'] as String? ?? 'unknown';
        
        if (packetsReceived > 0 || bytesReceived > 0) {
          Logger().i(
            "[RTP-IN] Inbound RTP ($kind): "
            "packets=$packetsReceived, "
            "bytes=$bytesReceived, "
            "loss=${reportData['packetsLost'] ?? 'N/A'}, "
            "jitter=${reportData['jitter'] ?? 'N/A'}"
          );
        }
        
        inboundRtpPackets += packetsReceived;
        inboundBytes += bytesReceived;
      }
      
      // [RTP-OUT] Outbound RTP statistics
      if (type == 'outbound-rtp') {
        final packetsSent = reportData['packetsSent'] as int? ?? 0;
        final bytesSent = reportData['bytesSent'] as int? ?? 0;
        final kind = reportData['kind'] as String? ?? 'unknown';
        
        if (packetsSent > 0 || bytesSent > 0) {
          Logger().i(
            "[RTP-OUT] Outbound RTP ($kind): "
            "packets=$packetsSent, "
            "bytes=$bytesSent, "
            "qualityLimitation=${reportData['qualityLimitation'] ?? 'none'}"
          );
        }
        
        outboundRtpPackets += packetsSent;
        outboundBytes += bytesSent;
      }
      
      // [ICE] Selected ICE candidate pair
      if (type == 'candidate-pair' && reportData['state'] == 'succeeded') {
        selectedIceCandidate = "relay/UDP"; // Simplified for brevity
      }
    }

    // [SUMMARY] Log media flow summary
    final summary = "[MEDIA-FLOW] $context\n"
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
```

**How to Read the Output:**
```
[MEDIA-FLOW] Periodic RTP stats check
  Inbound:  packets=1024, bytes=512000       ← Audio + video from remote
  Outbound: packets=2048, bytes=1024000      ← Audio + video to remote
  ICE:      relay/UDP                         ← Using TURN relay
  State:    connection=connected              ← Peer connected
```

**If packets=0:**
- ⚠️ Media NOT flowing
- Check: ICE state, TURN credentials, SDP content

---

## Critical Section 6: TURN-Only Debug Mode

**FILE:** lib/home.controller.dart  
**LOCATION:** Class property  
**USE:** For testing cross-network scenarios

```dart
// === TURN Validation Mode ===
/// Set to true to force relay-only (TURN-only) connections for cross-network testing.
/// When enabled, all media MUST flow through TURN relay candidates.
/// Useful for diagnosing why media works on same network but fails cross-network.
bool debugRelayOnly = false;
```

**How to Enable:**
```dart
// Change to:
bool debugRelayOnly = true;

// Then in createPeerConnection():
'iceTransportPolicy': debugRelayOnly ? 'relay' : 'all',
```

**Effect When Enabled:**
- Only relay candidates accepted
- Direct connections rejected
- All media goes through TURN
- Good for testing TURN configuration

**Expected Logs:**
```
[ICE] New candidate: ... relay/UDP
[ICE] New candidate: ... relay/TCP
Never see: [ICE] ... host
Never see: [ICE] ... srflx
```

---

## Log Lines to Monitor

**Success Indicators:**
```
[INIT] WebRTC initialization complete           ← Setup done
[OFFER] Offer sent via signaling                ← Offer created
[ANSWER] Answer sent via signaling              ← Answer created
[REMOTE-TRACK] Received track (kind=audio)      ← Audio arrived
[REMOTE-TRACK] Received track (kind=video)      ← Video arrived
[REMOTE-STREAM] Stream assigned: audio=1, video=1  ← Media ready
[RTP-IN] Inbound RTP: packets=1024              ← Data flowing
[MEDIA-FLOW] ICE: relay/UDP                     ← Using TURN
```

**Error Indicators:**
```
[ERROR] Cannot create offer: peer connection is null
[ERROR] getUserMedia failed
[ERROR] Failed to fetch TURN credentials
[SDP] Has m=audio: false                        ← Missing audio
[SDP] Has m=video: false                        ← Missing video
[SDP] Has a=sendrecv: false                     ← Not bidirectional
[WARNING] Received track but event.streams is empty
[MEDIA-FLOW] Inbound: packets=0, bytes=0        ← Media not flowing
```

---

## Testing Commands

**Monitor all initialization logs:**
```bash
adb logcat | grep "\[INIT\]\|\[MEDIA\]\|\[PEER\]"
```

**Monitor SDP negotiation:**
```bash
adb logcat | grep "\[SDP\]\|\[OFFER\]\|\[ANSWER\]"
```

**Monitor media flow:**
```bash
adb logcat | grep "\[RTP-\]\|\[MEDIA-FLOW\]"
```

**Monitor ICE candidates:**
```bash
adb logcat | grep "\[ICE\]"
```

**Find all errors:**
```bash
adb logcat | grep "\[ERROR\]"
```

---

## Summary of Critical Points

1. **Event listeners MUST be attached before addTrack()**
   - Missing: onTrack, onIceCandidate, etc.
   - Impact: Media won't render or ICE won't work

2. **Remote media rendering requires 3 lines**
   - remoteRenderer.srcObject = stream (assign)
   - remoteRenderer.muted = false (enable audio)
   - onRemoteStream?.call() (notify UI)

3. **SDP MUST contain**
   - m=audio
   - m=video
   - a=sendrecv

4. **RTP stats indicate actual media flow**
   - packets > 0 = media flowing
   - packets = 0 = check ICE, TURN, SDP

5. **TURN relay-only mode for testing**
   - debugRelayOnly = true
   - Forces all traffic through TURN

