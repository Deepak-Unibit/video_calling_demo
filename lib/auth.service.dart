import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:logger/web.dart';
import 'package:video_calling_demo/api/app.const.dart';
import 'package:video_calling_demo/api/url.api.dart';
import 'package:video_calling_demo/call.dart';
import 'package:video_calling_demo/loading.helper.dart';
import 'package:video_calling_demo/snackBar.helper.dart';
import 'package:video_calling_demo/socket.service.dart';

class AuthService {
  Map<String, dynamic>? currentUser;

  Future<void> register(String username, String email, String password) async {
    Map<String, String> userData = {'username': username, 'email': email, 'password': password};
    print('Registering user with data: $userData');
    try {
      LoadingPage.show();
      final response = await http.post(Uri.parse(UrlApi.register), headers: {'Content-Type': 'application/json', 'Accept': 'application/json'}, body: jsonEncode(userData));
      LoadingPage.close();
      print(UrlApi.register);
      print('Registration successful: ${response.body}');
      if (!response.body.contains('error')) {
        Map<String, dynamic> body = jsonDecode(response.body);
        if (body.containsKey("user")) {
          currentUser = body["user"];
          AppConst.authToken = body["token"];
          SocketService.instance.getSocketConnection();
          SnackBarHelper.success('Registration successful');
          Navigator.push(Get.context!, MaterialPageRoute(builder: (context) => CallPage()));
        } else {
          SnackBarHelper.error('Registration failed: Invalid response from server');
        }
        return;
      } else {
        SnackBarHelper.error('Registration failed: ${response.body}');
      }
    } on Exception catch (e) {
      print('Registration failed: $e');
    }
  }

  Future<void> login(String username, String email, String password) async {
    Map<String, String> userData = {'username': username, 'email': email, 'password': password};
    print('Logging in user with data: $userData');
    try {
      LoadingPage.show();
      final response = await http.post(Uri.parse(UrlApi.login), headers: {'Content-Type': 'application/json', 'Accept': 'application/json'}, body: jsonEncode(userData));
      LoadingPage.close();
      print(UrlApi.login);
      print('Login successful: ${response.body}');
      if (!response.body.contains('error')) {
        Map<String, dynamic> body = jsonDecode(response.body);
        if (body.containsKey("user")) {
          currentUser = body["user"];
          AppConst.authToken = body["token"];
          SocketService.instance.getSocketConnection();
          SnackBarHelper.success('Login successful');
          Navigator.push(Get.context!, MaterialPageRoute(builder: (context) => CallPage()));
        } else {
          SnackBarHelper.error('Login failed: Invalid response from server');
        }
        return;
      } else {
        SnackBarHelper.error('Login failed: ${response.body}');
      }
    } on Exception catch (e) {
      print('Login failed: $e');
    }
  }

  Future<dynamic> getTurnCredentials() async {
    try {
      LoadingPage.show();
      final response = await http.get(Uri.parse(UrlApi.turnCredentials), headers: {'Content-Type': 'application/json', 'Accept': 'application/json', 'authorization': 'Bearer ${AppConst.authToken}'});
      LoadingPage.close();
      Logger().i('TURN credentials fetched: ${response.body}');
      return jsonDecode(response.body);
    } catch (e) {
      print('Error fetching TURN credentials: $e');
    }
  }
}
