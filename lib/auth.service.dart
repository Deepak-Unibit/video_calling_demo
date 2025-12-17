import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:video_calling_demo/api/url.api.dart';

class AuthService {
  Future<void> register(String username, String email, String password) async {
    Map<String, String> userData = {'username': username, 'email': email, 'password': password};
    print('Registering user with data: $userData');
    try {
      final response = await http.post(Uri.parse(UrlApi.register), body: jsonEncode(userData), headers: {'Content-Type': 'application/json', 'Accept': '*/*'});
      print('Registration successful: ${response.body}');
    } on Exception catch (e) {
      print('Registration failed: $e');
    }
  }
}
