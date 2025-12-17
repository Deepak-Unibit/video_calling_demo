import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:proximity_screen_lock/proximity_screen_lock.dart';
import 'package:video_calling_demo/home.controller.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final HomeController controller = HomeController();
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _proximityLocked = false;

  Future<void> _toggleMute() async {
    try {
      final stream = controller.localRenderer.srcObject;
      if (stream != null) {
        for (final track in stream.getAudioTracks()) {
          track.enabled = _isMuted; // if currently muted, re-enable
        }
      }
      setState(() {
        _isMuted = !_isMuted;
      });
    } catch (_) {}
  }

  Future<void> _toggleSpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(!_isSpeakerOn);
      setState(() {
        _isSpeakerOn = !_isSpeakerOn;
      });
    } catch (_) {}
  }

  Future<void> _setProximity(bool active) async {
    try {
      await ProximityScreenLock.setActive(active);
      if (mounted) {
        setState(() {
          _proximityLocked = active;
        });
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    // Initialize renderers and setup socket listeners
    controller.initializeRenderers().then((_) {
      if (mounted) setState(() {});
    });

    // Refresh UI when remote stream arrives
    controller.onRemoteStream = () {
      if (mounted) setState(() {});
    };

    // Refresh UI when timer updates
    controller.onTimerUpdate = () {
      // First timer tick indicates call is active; enable proximity lock
      if (!_proximityLocked) {
        _setProximity(true);
      }
      if (mounted) setState(() {});
    };

    controller.onStatusUpdate = () {
      if (mounted) setState(() {});
    };
  }

  @override
  Widget build(BuildContext context) {
    final inCall = controller.callId.isNotEmpty;
    final name = controller.textEditingController.text.isNotEmpty ? controller.textEditingController.text : "Unknown";
    final duration = (controller.timeString.isEmpty) ? "00:00" : controller.timeString;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)]),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 24),
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    SizedBox(width: 48),
                    Text(
                      'Audio Call',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(width: 48),
                  ],
                ),

                // Proximity status
                if (_proximityLocked) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.center,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF27AE60).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0xFF27AE60).withOpacity(0.6)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.sensor_occupied, color: Color(0xFF27AE60), size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Proximity On',
                            style: TextStyle(color: Color(0xFF27AE60), fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const Spacer(),

                // Avatar with gradient ring
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [Color(0xFF56CCF2), Color(0xFF2F80ED)]),
                  ),
                  child: const CircleAvatar(
                    radius: 64,
                    backgroundColor: Colors.black26,
                    child: Icon(Icons.person, size: 64, color: Colors.white70),
                  ),
                ),

                const SizedBox(height: 20),
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 0.3),
                ),
                const SizedBox(height: 8),
                Text(controller.statusString ?? (inCall ? 'Connected' : 'Ready'), style: const TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 6),
                Text(
                  duration,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),

                const Spacer(),

                // Input + Call (when not in call)
                if (!inCall) ...[
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller.textEditingController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: "Enter recipient ID",
                              hintStyle: TextStyle(color: Colors.white70),
                              border: InputBorder.none,
                              prefixIcon: const Icon(Icons.person_outline, color: Colors.white70),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF27AE60),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () => controller.initiateCall(controller.textEditingController.text),
                          child: const Text('Call'),
                        ),
                      ],
                    ),
                  ),
                ],

                // Controls (when in call)
                if (inCall) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RoundControl(icon: _isMuted ? Icons.mic_off : Icons.mic, color: _isMuted ? Colors.orange : Colors.white, background: Colors.white10, onPressed: _toggleMute),
                      _RoundControl(
                        icon: Icons.call_end,
                        color: Colors.white,
                        background: const Color(0xFFE74C3C),
                        size: 72,
                        onPressed: () {
                          controller.endCall();
                          _setProximity(false);
                        },
                      ),
                      _RoundControl(
                        icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_mute,
                        color: _isSpeakerOn ? Colors.lightBlueAccent : Colors.white,
                        background: Colors.white10,
                        onPressed: _toggleSpeaker,
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 20),

                // Hidden renderer (needed for audio playback on some platforms)
                SizedBox(width: 1, height: 1, child: RTCVideoView(controller.remoteRenderer)),

                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Make sure proximity lock is released when leaving screen
    ProximityScreenLock.setActive(false);
    super.dispose();
  }
}

class _RoundControl extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color background;
  final double size;
  final VoidCallback onPressed;

  const _RoundControl({required this.icon, required this.color, required this.background, required this.onPressed, this.size = 64, super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Center(
            child: Icon(icon, color: color, size: size * 0.42),
          ),
        ),
      ),
    );
  }
}
