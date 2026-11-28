// Versions are numbers only from 1.15.0 on (releases.md section 4): X.Y.0 is
// a stable release, X.Y.Z with Z above 0 is a beta on the way to X.(Y+1).0.
// The older releases keep the meaning they were published with, because the
// copies installed from them are still updating.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/update_models.dart';

void main() {
  test('which version is a beta', () {
    // Before the change: the label decides, the last number says nothing.
    expect(isBetaVersion('1.14.3'), isFalse);
    expect(isBetaVersion('1.14.1-beta.5'), isTrue);
    expect(isBetaVersion('1.2.9'), isFalse);
    // From 1.15.0: the last number decides.
    expect(isBetaVersion('1.15.0'), isFalse);
    expect(isBetaVersion('1.15.1'), isTrue);
    expect(isBetaVersion('1.15.12'), isTrue);
    expect(isBetaVersion('1.16.0'), isFalse);
    expect(isBetaVersion('2.0.0'), isFalse);
    expect(isBetaVersion('2.0.3+401234'), isTrue);
    // A label, should one ever be published again, is still a beta.
    expect(isBetaVersion('1.16.0-beta.1'), isTrue);
  });

  test('the order a person expects: betas lead to the next stable', () {
    final order = ['1.14.3', '1.15.0', '1.15.1', '1.15.2', '1.15.10', '1.16.0'];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(compareSemver(order[i], order[i + 1]), -1,
          reason: '${order[i]} < ${order[i + 1]}');
    }
  });

  test('an update folder: a beta is known by its number', () {
    Map<String, dynamic> file(String v) =>
        {'x': 'a' * 64, 'name': 'xprs-$v-linux-x64.tar.gz', 'size': 1};
    final rel = {
      for (final r in releasesFromFolder({
        'files': [file('1.14.3'), file('1.15.0'), file('1.15.1'), file('1.14.1-beta.5')],
      }))
        r.version: r.isPrerelease,
    };
    expect(rel, {'1.14.3': false, '1.15.0': false, '1.15.1': true, '1.14.1-beta.5': true});
  });

  test('the feed: a beta is one even when the document does not say', () {
    ReleaseInfo feed(String v, {bool? pre}) => ReleaseInfo.fromFeed(
        {'version': v, 'tagName': 'v$v', 'prerelease': ?pre, 'assets': const []});
    expect(feed('1.15.1').isPrerelease, isTrue);
    expect(feed('1.15.1', pre: false).isPrerelease, isTrue);
    expect(feed('1.16.0', pre: false).isPrerelease, isFalse);
    expect(feed('1.14.3').isPrerelease, isFalse);
    expect(feed('1.14.1-beta.5', pre: true).isPrerelease, isTrue);
  });
}
