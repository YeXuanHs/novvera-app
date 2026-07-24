import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:novvera/foundation/cache_manager.dart';
import 'package:novvera/foundation/comic_source/comic_source.dart';
import 'package:novvera/foundation/consts.dart';
import 'package:novvera/foundation/novel_backend/huanmeng_client.dart';
import 'package:novvera/foundation/novel_backend/linovelib_client.dart';
import 'package:novvera/foundation/novel_backend/wenku8_client.dart';
import 'package:novvera/utils/image.dart';

import 'app_dio.dart';

abstract class ImageDownloader {
  static const _wenku8CoverPrefix = 'novvera://wenku8/cover/';
  static const _huanmengCoverPrefix = 'novvera://huanmeng/cover/';
  static final _linovelibCoverHost = RegExp(
    r'linovelib\.com/files/article/image/',
    caseSensitive: false,
  );

  static Stream<ImageDownloadProgress> loadThumbnail(
      String url, String? sourceKey,
      [String? cid]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      if (_looksLikeImage(data)) {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      }
      await CacheManager().delete(cacheKey);
    }

    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(milliseconds: 200 * attempt));
      }
      try {
        yield* _downloadThumbnailOnce(url, sourceKey, cid, cacheKey);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? "Error: Empty response body.";
  }

  static Stream<ImageDownloadProgress> _downloadThumbnailOnce(
    String url,
    String? sourceKey,
    String? cid,
    String cacheKey,
  ) async* {
    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }

    // Wenku8: CDN often 404; fetch JPEG from App API.
    if (requestUrl.startsWith(_wenku8CoverPrefix) ||
        (sourceKey == 'wenku8' &&
            requestUrl.contains('img.wenku8.com/image/'))) {
      final aid = requestUrl.startsWith(_wenku8CoverPrefix)
          ? requestUrl.substring(_wenku8CoverPrefix.length)
          : RegExp(r'/(\d+)/\1s?\.jpg').firstMatch(requestUrl)?.group(1);
      if (aid != null && aid.isNotEmpty) {
        final bytes = await Wenku8Client.instance.fetchCoverBytes(aid);
        await CacheManager().writeCache(cacheKey, bytes);
        yield ImageDownloadProgress(
          currentBytes: bytes.length,
          totalBytes: bytes.length,
          imageBytes: bytes,
        );
        return;
      }
    }

    // Huanmeng: list/home often has text-only links with no cover img.
    // Resolve real cover from detail page, then download like a normal URL.
    if (requestUrl.startsWith(_huanmengCoverPrefix)) {
      final aid = requestUrl.substring(_huanmengCoverPrefix.length);
      if (aid.isEmpty) {
        throw 'Error: Empty huanmeng cover aid.';
      }
      requestUrl = await HuanmengClient.instance.resolveCoverUrl(aid);
      configs['url'] = requestUrl;
    }

    // Linovelib covers sit behind Cloudflare: Dio often gets HTML, browser OK.
    // Fetch via client (Dio then WebView) the same way Playwright MCP can.
    if (sourceKey == 'linovelib' || _linovelibCoverHost.hasMatch(requestUrl)) {
      final bytes =
          await LinovelibClient.instance.fetchCoverBytes(requestUrl);
      await CacheManager().writeCache(cacheKey, bytes);
      yield ImageDownloadProgress(
        currentBytes: bytes.length,
        totalBytes: bytes.length,
        imageBytes: bytes,
      );
      return;
    }

    var dio = AppDio(BaseOptions(
      headers: Map<String, dynamic>.from(configs['headers']),
      method: configs['method'] ?? 'GET',
      responseType: ResponseType.stream,
    ));

    var req = await dio.request<ResponseBody>(requestUrl, data: configs['data']);
    final status = req.statusCode ?? 0;
    if (status >= 400) {
      throw "Invalid Status Code: $status";
    }
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    final bytes = buffer is Uint8List ? buffer : Uint8List.fromList(buffer);
    if (!_looksLikeImage(bytes)) {
      throw "Error: Response is not an image.";
    }

    await CacheManager().writeCache(cacheKey, bytes);
    yield ImageDownloadProgress(
      currentBytes: bytes.length,
      totalBytes: bytes.length,
      imageBytes: bytes,
    );
  }

  static bool _looksLikeImage(List<int> data) {
    if (data.length < 8) return false;
    // JPEG
    if (data[0] == 0xFF && data[1] == 0xD8) return true;
    // PNG
    if (data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true;
    }
    // GIF
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return true;
    // WEBP (RIFF....WEBP)
    if (data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data.length > 11 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      return true;
    }
    // AVIF / HEIC often start with ftyp
    if (data.length > 12 &&
        data[4] == 0x66 &&
        data[5] == 0x74 &&
        data[6] == 0x79 &&
        data[7] == 0x70) {
      return true;
    }
    return false;
  }

  static final _loadingImages = <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
      String imageKey, String? sourceKey, String cid, String eid) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
      String imageKey, String? sourceKey, String cid, String eid) {
    return _loadComicImage(imageKey, sourceKey, cid, eid);
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
      String imageKey, String? sourceKey, String cid, String eid) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = (await comicSource!.getImageLoadingConfig
              ?.call(imageKey, cid, eid)) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {
          'user-agent': webUA,
        };

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(BaseOptions(
          headers: configs['headers'],
          method: configs['method'] ?? 'GET',
          responseType: ResponseType.stream,
        ));

        final imageUrl = configs['url'] ?? imageKey;
        var req = await dio.request<ResponseBody>(imageUrl, data: configs['data']);
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([Uint8List.fromList(buffer)]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    }
    catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    }
    finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
