
import 'package:video_calling_demo/api/app.const.dart';

class UrlApi {
  static const String baseUrl = '${AppConst.baseUrl}/api';

  // Auth
  static const String register = "$baseUrl/users/register";
  static const String login = "$baseUrl/users/login";

  // TURN Server
  static const String turnCredentials = "$baseUrl/calls/turn-credentials";

}
