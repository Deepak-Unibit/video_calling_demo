import 'package:flutter/material.dart';
import 'package:video_calling_demo/login.dart';
import 'package:video_calling_demo/register.dart';
import 'package:video_calling_demo/video_player_screen.dart';

class LandingPage extends StatelessWidget {
  const LandingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Landing Page')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => RegisterView()));
              },
              child: Text('Go to Register'),
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => LoginView()));
              },
              child: Text('Go to Login'),
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const VideoPlayerScreen(videoPath: '/data/user/0/com.example.video_calling_demo/cache/call_1766066785181.mp4')),
                );
              },
              child: Text('Play Video'),
            ),
          ],
        ),
      ),
    );
  }
}
