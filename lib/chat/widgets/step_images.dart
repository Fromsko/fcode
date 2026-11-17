import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../../ui/widgets/image_gallery.dart';
import '../chat_models.dart';
import 'image_deck.dart';
import 'step_header.dart';

/// 工具返回的图片只在标题下显示一份，复用消息图片的比例和预览。
class ToolImages extends StatelessWidget {
  const ToolImages({super.key, required this.images});

  final List<ImageAttachment> images;

  @override
  Widget build(BuildContext context) => images.isEmpty
      ? const SizedBox.shrink()
      : Align(
          alignment: Alignment.centerLeft,
          child: ImageDeck(
            images: images.map(GalleryImage.fromAttachment).toList(),
            tr: AppState.phrase,
          ),
        );
}

/// 步骤收起时标题行尾的小图：只放第一张，其余写张数；点它直接看大图，
/// 不展开步骤。和电脑端一样，展开后换成 [ToolImages]。
class StepThumbnails extends StatelessWidget {
  const StepThumbnails({super.key, required this.images});

  final List<ImageAttachment> images;

  static const width = 36.0;
  static const height = 22.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(3);
    return SelectionContainer.disabled(
      child: StepHeaderOwnTap(
        child: GestureDetector(
          key: const ValueKey('step-thumbnails'),
          behavior: HitTestBehavior.opaque,
          onTap: () => showImageGallery(
            context,
            images.map(GalleryImage.fromAttachment).toList(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                foregroundDecoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: Image.memory(
                    images.first.bytes,
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    gaplessPlayback: true,
                    cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                  ),
                ),
              ),
              if (images.length > 1) ...[
                const SizedBox(width: 4),
                Text(
                  '+${images.length - 1}',
                  style: MobileTheme.metaStyleOf(context),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
