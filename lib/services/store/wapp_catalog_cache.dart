/// Where a fetched catalog and its icons are kept between runs, so a phone
/// without internet still lists what it knew. The native half writes files
/// under the support directory; the web build keeps them for the session.
library;

export 'wapp_catalog_cache_stub.dart'
    if (dart.library.io) 'wapp_catalog_cache_io.dart';
