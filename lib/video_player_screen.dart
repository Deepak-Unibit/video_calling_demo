import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.videoPath});

  final String videoPath;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      final videoFile = File(widget.videoPath);
      print('Attempting to play: ${widget.videoPath}');
      print('File exists: ${await videoFile.exists()}');
      print('File size: ${await videoFile.exists() ? await videoFile.length() : 0} bytes');

      if (!await videoFile.exists()) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Video file not found: ${widget.videoPath}';
        });
        return;
      }

      if (await videoFile.length() == 0) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Video file is empty';
        });
        return;
      }

      _controller = VideoPlayerController.file(videoFile);
      await _controller.initialize();
      setState(() {
        _isLoading = false;
      });
      _controller.play();
    } catch (e) {
      print('Video player error: $e');
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load video: ${e.toString()}\n\nPath: ${widget.videoPath}';
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Video Player'), backgroundColor: Colors.black87),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _errorMessage != null
          ? Center(
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            )
          : Padding(
              padding: const EdgeInsets.only(bottom: 30),
              child: Stack(
                children: [
                  Center(
                    child: AspectRatio(aspectRatio: _controller.value.aspectRatio, child: VideoPlayer(_controller)),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VideoProgressIndicator(
                            _controller,
                            allowScrubbing: true,
                            colors: VideoProgressColors(playedColor: Colors.green, bufferedColor: Colors.grey, backgroundColor: Colors.grey.withOpacity(0.3)),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                icon: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                                onPressed: () {
                                  setState(() {
                                    _controller.value.isPlaying ? _controller.pause() : _controller.play();
                                  });
                                },
                              ),
                              Text(
                                '${_formatDuration(_controller.value.position)} / ${_formatDuration(_controller.value.duration)}',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                              IconButton(
                                icon: const Icon(Icons.fullscreen, color: Colors.white),
                                onPressed: () {
                                  // Optional: implement full screen
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
