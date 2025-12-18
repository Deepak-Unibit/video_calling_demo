import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SnackBarHelper {
  static void error(String? message) {
    Get.closeAllSnackbars();
    Get.snackbar(
      'Error'.tr,
      message?.tr ?? 'Something went wrong'.tr,
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.red.withOpacity(0.7),
      colorText: Colors.white,
      duration: const Duration(seconds: 2),
      margin: const EdgeInsets.only(bottom: 20),
      maxWidth: 330,
      icon: const Icon(Icons.cancel_outlined, size: 24, color: Colors.white),
    );
  }

  static void success(String? message) {
    Get.closeAllSnackbars();
    Get.snackbar(
      'Success'.tr,
      message?.tr ?? 'Success'.tr,
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.green.withOpacity(0.7),
      colorText: Colors.white,
      duration: const Duration(seconds: 1),
      margin: const EdgeInsets.only(bottom: 20),
      maxWidth: 330,
      icon: const Icon(
        Icons.check_circle_outline_rounded,
        size: 24,
        color: Colors.white,
      ),
    );
  }

  static void message({
    String message = "",
    String text = "",
    Function? onClick,
  }) {
    Get.closeAllSnackbars();
    Get.snackbar(
      message.tr,
      text.tr,
      snackPosition: SnackPosition.TOP,
      backgroundColor: Get.context!.theme.colorScheme.onPrimary,
      colorText: Colors.black,
      duration: const Duration(seconds: 3),
      margin: const EdgeInsets.only(bottom: 20),
      maxWidth: 330,
      dismissDirection: DismissDirection.horizontal,
      icon: const Icon(Icons.message, size: 24, color: Colors.black),
      onTap: (snack) {
        if (onClick != null) {
          onClick();
        }
      },
    );
  }
}
