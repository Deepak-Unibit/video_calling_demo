import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:video_calling_demo/auth.service.dart';
import 'package:video_calling_demo/home.dart';

class CallPage extends StatelessWidget {
  const CallPage({super.key});

  @override
  Widget build(BuildContext context) {
    AuthService authService = Get.find<AuthService>();
    TextEditingController idController = TextEditingController();
    List<String> presetIds = ["69425a3818b7ca50b9f1e662", "69425a1618b7ca50b9f1e65f", "6943afde0b010650e02f7a97"];
    presetIds.remove(authService.currentUser?['id'] ?? "");
    return Scaffold(
      appBar: AppBar(title: const Text('Call Page')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Welcome, ${authService.currentUser?['username'] ?? 'Guest'}'),
            const SizedBox(height: 20),
            Text("Your number: ${authService.currentUser?['id'] ?? 'N/A'}"),
            const SizedBox(height: 40),
            TextFormField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'ID', border: OutlineInputBorder()),

              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter an ID';
                }

                return null;
              },
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                if (idController.text.isNotEmpty) Navigator.push(context, MaterialPageRoute(builder: (context) => HomePage()));
              },
              child: const Text('Start Call'),
            ),

            SizedBox(height: 24),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: presetIds
                  .map(
                    (platform) => ElevatedButton(
                      onPressed: () {
                        Navigator.push(context, MaterialPageRoute(builder: (context) => HomePage()));
                      },
                      child: Text(platform),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}
