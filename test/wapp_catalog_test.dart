// The catalog the store reads has two shapes, and the store must see one list
// out of either: the object at https://xprs.dev/apps/catalog.json, and the
// older flat index of every version ever packaged. What is protected here is
// the wire the wasm parses (file as "<name>/<leaf>"), the absolute URL and
// digest the host installs from, and newest-version collapsing of the old
// shape.

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/store/wapp_catalog.dart';
import 'package:xprs/services/store/wapp_catalog_service.dart';

const _catalogJson = '''
{
  "schema": "xprs.apps.catalog/1",
  "generated": "2026-09-14T12:00:00Z",
  "base": "https://xprs.dev/apps/",
  "apps": [
    {
      "name": "widget_demo",
      "id": "tools.xprs.widget-demo",
      "version": "1.0.2",
      "kind": "system",
      "title": "Functionality Demo",
      "description": "Demo wapp providing multiple functionalities.",
      "summary": "Minimal provider wapp.",
      "descriptions": {
        "en": {"title": "Functionality Demo", "summary": "Demo wapp", "body": "Minimal provider wapp."},
        "pt": {"title": "Demo de Funcionalidades", "summary": "Wapp de demonstracao", "body": "Fornecedor minimo."}
      },
      "icon": "widget_demo/media/icons/widget-demo.svg",
      "color": null,
      "tags": ["system", "demo"],
      "platforms": [],
      "permissions": [],
      "screenshots": [{"file": "widget_demo/store/screenshots/01-home.png", "caption": "home"}],
      "file": "binaries/widget_demo/widget_demo-1.0.2.wapp",
      "size": 7689,
      "sha256": "5900BAB628C5270B4373AF1635DF65803B4EAE1233D3F679DCE944243A4DC977",
      "changelog": null,
      "source_url": "https://github.com/xprs-dev/apps/tree/main/widget_demo"
    }
  ]
}
''';

const _indexJson = '''
[
  {"file":"aprs/aprs-0.2.5.wapp","id":"tools.geogram.aprs","version":"0.2.5","size":84586,"title":"APRS","description":"old"},
  {"file":"aprs/aprs-0.2.80.wapp","id":"tools.geogram.aprs","version":"0.2.80","size":168045,"title":"APRS","description":"new"},
  {"file":"aprs/aprs-0.2.9.wapp","id":"tools.geogram.aprs","version":"0.2.9","size":90000,"title":"APRS","description":"mid"},
  {"file":"chat/chat-0.7.27.wapp","id":"tools.xprs.chat","version":"0.7.27","size":1,"description":"Chat"}
]
''';

void main() {
  group('xprs.apps.catalog/1', () {
    final doc = parseCatalog(_catalogJson, sourceBase: 'https://example.invalid/');

    test('resolves every path against the document base', () {
      final app = doc.apps.single;
      expect(doc.base, 'https://xprs.dev/apps/');
      expect(app.url, 'https://xprs.dev/apps/binaries/widget_demo/widget_demo-1.0.2.wapp');
      expect(app.iconUrl, 'https://xprs.dev/apps/widget_demo/media/icons/widget-demo.svg');
      expect(app.screenshots, ['https://xprs.dev/apps/widget_demo/store/screenshots/01-home.png']);
      expect(app.file, 'widget_demo-1.0.2.wapp');
      expect(app.size, 7689);
      expect(app.sha256, '5900bab628c5270b4373af1635df65803b4eae1233d3f679dce944243a4dc977');
    });

    test('hands the wasm the six-field entry it always parsed', () {
      final e = doc.apps.single.toIndexEntry();
      expect(e['file'], 'widget_demo/widget_demo-1.0.2.wapp');
      expect(e['id'], 'tools.xprs.widget-demo');
      expect(e['version'], '1.0.2');
      expect(e['size'], 7689);
      expect(e['title'], 'Functionality Demo');
      expect(e.keys.toSet(), {'file', 'id', 'version', 'size', 'title', 'description'});
    });

    test('picks text by language with English behind it', () {
      final app = doc.apps.single;
      expect(app.titleFor('pt'), 'Demo de Funcionalidades');
      expect(app.descriptionFor('de'), 'Demo wapp');
      expect(doc.generated, isNotNull);
    });

    test('refuses an object that is not a catalog', () {
      expect(() => parseCatalog('{"hello": 1}', sourceBase: 'x'), throwsFormatException);
      expect(() => parseCatalog('42', sourceBase: 'x'), throwsFormatException);
    });
  });

  group('flat index.json', () {
    test('collapses to the newest version per slug, numerically', () {
      final doc = parseCatalog(_indexJson, sourceBase: 'https://xprs.dev/wapps/');
      expect(doc.apps.map((a) => a.name).toList(), ['aprs', 'chat']);
      final aprs = doc.app('aprs')!;
      expect(aprs.version, '0.2.80');
      expect(aprs.url, 'https://xprs.dev/wapps/aprs/aprs-0.2.80.wapp');
      expect(aprs.sha256, '');
      final chat = doc.app('chat')!;
      expect(chat.title, 'Chat', reason: 'a pre-title index puts the label in description');
      expect(chat.description, '');
    });
  });

  group('helpers', () {
    test('version compare is numeric per segment', () {
      expect(catalogVersionCmp('0.2.80', '0.2.9'), greaterThan(0));
      expect(catalogVersionCmp('1.0', '1.0.0'), 0);
      // A suffix counts as more segments, as the host has always read it.
      expect(catalogVersionCmp('1.0.0-beta.4', '1.0.0'), greaterThan(0));
      expect(catalogVersionCmp('0.9', '1.0'), lessThan(0));
    });

    test('slug drops the version and extension', () {
      expect(catalogSlug('aprs-0.2.60.wapp'), 'aprs');
      expect(catalogSlug('binaries/widget_demo/widget_demo-1.0.2.wapp'), 'widget_demo');
      expect(catalogSlug('app-creator-0.3.5.wapp'), 'app-creator');
      expect(catalogSlug('chat'), 'chat');
    });

    test('a source is a directory unless it names a .json', () {
      expect(WappCatalogService.candidateUrls('https://xprs.dev/apps/'),
          ['https://xprs.dev/apps/catalog.json', 'https://xprs.dev/apps/index.json']);
      expect(WappCatalogService.candidateUrls('https://h/x/catalog.json'),
          ['https://h/x/catalog.json']);
      expect(WappCatalogService.isHttpSource('HTTPS://xprs.dev/apps'), isTrue);
      expect(WappCatalogService.isHttpSource('rns:npub1abc'), isFalse);
      expect(WappCatalogService.defaultSource, 'https://xprs.dev/apps');
    });
  });
}
