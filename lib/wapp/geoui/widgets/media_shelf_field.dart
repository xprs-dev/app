// A GeoUI field (`$type:"media"`) that shows files by their tokens: a grid of
// pictures (a gallery's photos and films) or a list of named files (tracks,
// documents). Each tile is a MediaThumbnail, so fetching, progress and the
// viewer are the ones every other screen has; a wapp only names the files.
//
// Value: {"layout":"grid|list","items":[{"token","preview","title",
// "subtitle"}]}. `preview` is the small picture drawn for `token` when it has
// one (the viewer then offers the original).
import 'package:flutter/material.dart';
import 'package:reticulum/reticulum.dart' show MediaRef;

import 'media_view.dart';

class MediaShelfField extends StatelessWidget {
  const MediaShelfField({super.key, required this.value});
  final Map<String, dynamic> value;

  static IconData _iconOf(String ext) {
    const audio = {'mp3', 'flac', 'ogg', 'oga', 'opus', 'm4a', 'wav', 'aac'};
    const video = {'mp4', 'm4v', 'mov', 'webm', 'mkv', 'ogv'};
    const image = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp', 'heic'};
    const book = {'epub', 'mobi', 'azw', 'azw3', 'fb2', 'djvu'};
    const pack = {'zip', '7z', 'rar', 'tar', 'gz', 'tgz', 'bz2', 'xz'};
    if (audio.contains(ext)) return Icons.music_note;
    if (video.contains(ext)) return Icons.movie_outlined;
    if (image.contains(ext)) return Icons.image_outlined;
    if (book.contains(ext)) return Icons.menu_book_outlined;
    if (pack.contains(ext)) return Icons.folder_zip_outlined;
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (ext == 'apk') return Icons.android;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final items = (value['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    MediaRef? ref(Object? t) => t == null || '$t'.isEmpty ? null : MediaRef.parse('$t');

    if (value['layout'] == 'grid') {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180, mainAxisSpacing: 6, crossAxisSpacing: 6),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final it = items[i];
          final shown = ref(it['preview']) ?? ref(it['token']);
          if (shown == null) return const SizedBox.shrink();
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: MediaThumbnail(
                  ref: shown, showSize: false),
            ),
          );
        },
      );
    }
    return Column(
      children: [
        for (final it in items)
          if (ref(it['token']) case final r?)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: CircleAvatar(
                backgroundColor: cs.secondaryContainer,
                child: Icon(_iconOf(r.ext), color: cs.onSecondaryContainer),
              ),
              title: Text('${it['title'] ?? ''}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: '${it['subtitle'] ?? ''}'.isEmpty
                  ? null
                  : Text('${it['subtitle']}',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => MediaViewerPage.open(context, r),
            ),
      ],
    );
  }
}
