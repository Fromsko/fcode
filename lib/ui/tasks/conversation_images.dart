import 'package:bao_link/bao_link.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/user_facing_error.dart';
import '../../state/app_state.dart';
import '../../state/conversation_input.dart';

/// 私聊、智能体和群聊共用选择、格式与 wire 大小校验。
Future<List<DraftImage>> pickConversationImages(
  AppState state, {
  ImageSource? source,
}) async {
  final List<XFile> files;
  if (source == ImageSource.camera) {
    final file = await ImagePicker().pickImage(source: ImageSource.camera);
    files = file == null ? [] : [file];
  } else {
    files = await ImagePicker().pickMultiImage();
  }
  final picked = <DraftImage>[];
  for (final file in files) {
    if (await file.length() >= LinkLimits.image) {
      throw UserFacingError(
        state.tr('每张图片必须小于 8 MB', 'Each image must be under 8 MB'),
      );
    }
    final bytes = await file.readAsBytes();
    if (4 * ((bytes.length + 2) ~/ 3) >= LinkLimits.image) {
      throw UserFacingError(
        state.tr(
          '图片的 base64 数据必须小于 8 MB',
          'Base64 image data must be under 8 MB',
        ),
      );
    }
    final type =
        file.mimeType ??
        switch (file.name.toLowerCase().split('.').last) {
          'png' => 'image/png',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          'jpg' || 'jpeg' => 'image/jpeg',
          _ => '',
        };
    if (![
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
    ].contains(type)) {
      throw UserFacingError(state.tr('不支持此图片格式', 'Unsupported image format'));
    }
    picked.add(DraftImage(file.name, type, bytes));
  }
  return picked;
}
