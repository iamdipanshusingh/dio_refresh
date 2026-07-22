import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_refresh/dio_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resolves requests from a per-path response queue (no real network).
class _MockApiInterceptor extends Interceptor {
  _MockApiInterceptor(this._queues);

  final Map<String, List<int>> _queues;
  final Map<String, int> _indexes = {};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.uri.path;
    final statuses = _queues[path];
    if (statuses == null || statuses.isEmpty) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: 'No mock for $path',
          type: DioExceptionType.unknown,
        ),
      );
      return;
    }

    final index = _indexes[path] ?? 0;
    _indexes[path] = index + 1;
    final status = statuses[index.clamp(0, statuses.length - 1)];

    final response = Response(
      requestOptions: options,
      statusCode: status,
      data: status == 200 ? {'ok': true} : 'unauthorized',
    );

    if (status >= 200 && status < 300) {
      handler.resolve(response);
    } else {
      // callFollowingErrorInterceptor: so DioRefreshInterceptor.onError runs.
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
        ),
        true,
      );
    }
  }
}

/// Always succeeds — used on the retry Dio so retries never hit the network.
class _OkRetryInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.resolve(Response(
      requestOptions: options,
      statusCode: 200,
      data: {'ok': true},
    ));
  }
}

/// Holds the first request to [gatedPath] until [gate] completes, then 401s it.
class _GatedMockInterceptor extends Interceptor {
  _GatedMockInterceptor({
    required this.gate,
    required this.gatedPath,
    required this.delegate,
  });

  final Completer<void> gate;
  final String gatedPath;
  final _MockApiInterceptor delegate;
  bool _held = false;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.uri.path == gatedPath && !_held) {
      _held = true;
      await gate.future;
      final response = Response(
        requestOptions: options,
        statusCode: 401,
        data: 'unauthorized',
      );
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
        ),
        true,
      );
      return;
    }
    delegate.onRequest(options, handler);
  }
}

DioRefreshInterceptor _refreshInterceptor({
  required TokenManager tokenManager,
  required void Function() onRefresh,
  TokenStore Function(TokenStore)? refreshResult,
  Future<void>? holdRefresh,
}) {
  return DioRefreshInterceptor(
    tokenManager: tokenManager,
    shouldRefresh: (response) => response?.statusCode == 401,
    isTokenValid: (_) => true,
    authHeader: (store) => {
      'Authorization': 'Bearer ${store.accessToken}',
    },
    retryInterceptors: [_OkRetryInterceptor()],
    onRefresh: (dio, store) async {
      onRefresh();
      if (holdRefresh != null) {
        await holdRefresh;
      }
      return refreshResult?.call(store) ??
          TokenStore(
            accessToken: 'refreshed-access',
            refreshToken: 'refreshed-refresh',
          );
    },
  );
}

void main() {
  late TokenManager tokenManager;

  setUp(() {
    tokenManager = TokenManager.instance;
    tokenManager.resetForTest();
    tokenManager.setToken(TokenStore(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    ));
  });

  test('concurrent 401s trigger onRefresh only once', () async {
    var refreshCalls = 0;
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();

    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    dio.interceptors.addAll([
      _refreshInterceptor(
        tokenManager: tokenManager,
        onRefresh: () {
          refreshCalls++;
          if (!refreshStarted.isCompleted) {
            refreshStarted.complete();
          }
        },
        holdRefresh: releaseRefresh.future,
        refreshResult: (store) => TokenStore(
          accessToken: store.accessToken,
          refreshToken: store.refreshToken,
        ),
      ),
      _MockApiInterceptor({
        '/a': [401, 200],
        '/b': [401, 200],
      }),
    ]);

    final futures = Future.wait([
      dio.get('/a'),
      dio.get('/b'),
    ]);

    await refreshStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(refreshCalls, 1);

    releaseRefresh.complete();
    final results = await futures;
    expect(results.map((r) => r.statusCode), [200, 200]);
    expect(refreshCalls, 1);
  });

  test('second interceptor instance shares the refresh lock', () async {
    var refreshCalls = 0;
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();

    Dio buildClient(String path) {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
      dio.interceptors.addAll([
        _refreshInterceptor(
          tokenManager: tokenManager,
          onRefresh: () {
            refreshCalls++;
            if (!refreshStarted.isCompleted) {
              refreshStarted.complete();
            }
          },
          holdRefresh: releaseRefresh.future,
        ),
        _MockApiInterceptor({
          path: [401, 200],
        }),
      ]);
      return dio;
    }

    final futures = Future.wait([
      buildClient('/a').get('/a'),
      buildClient('/b').get('/b'),
    ]);

    await refreshStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(refreshCalls, 1);

    releaseRefresh.complete();
    final results = await futures;
    expect(results.map((r) => r.statusCode), [200, 200]);
    expect(refreshCalls, 1);
  });

  test('late 401 after refresh retries without calling onRefresh again',
      () async {
    var refreshCalls = 0;
    final gate = Completer<void>();

    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    final mock = _MockApiInterceptor({
      '/first': [401, 200],
      '/late': [200],
    });
    dio.interceptors.addAll([
      _refreshInterceptor(
        tokenManager: tokenManager,
        onRefresh: () => refreshCalls++,
        refreshResult: (store) => TokenStore(
          accessToken: store.accessToken,
          refreshToken: store.refreshToken,
        ),
      ),
      _GatedMockInterceptor(
        gate: gate,
        gatedPath: '/late',
        delegate: mock,
      ),
    ]);

    final lateFuture = dio.get('/late');
    await dio.get('/first');
    expect(refreshCalls, 1);

    gate.complete();
    final late = await lateFuture;
    expect(late.statusCode, 200);
    expect(refreshCalls, 1);
  });

  test('does not refresh or retry when request was sent without access token '
      'but TokenManager gains tokens before onError', () async {
    tokenManager.resetForTest();
    tokenManager.setToken(TokenStore(
      accessToken: null,
      refreshToken: null,
    ));

    var refreshCalls = 0;
    var retried = false;

    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    dio.interceptors.add(
      DioRefreshInterceptor(
        tokenManager: tokenManager,
        shouldRefresh: (response) => response?.statusCode == 401,
        isTokenValid: (_) => true,
        authHeader: (store) {
          if (store.accessToken == null) return {};
          return {
            'authorization': 'Bearer ${store.accessToken}',
            'x-refresh-token': store.refreshToken ?? '',
          };
        },
        retryInterceptors: [
          InterceptorsWrapper(
            onRequest: (options, handler) {
              retried = true;
              handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: {'ok': true},
              ));
            },
          ),
        ],
        onRefresh: (dio, store) async {
          refreshCalls++;
          return TokenStore(
            accessToken: 'new-a',
            refreshToken: 'new-r',
          );
        },
      ),
    );
    dio.httpClientAdapter = _CallbackAdapter((options) {
      // Login / another Network.request setToken while this call is in flight.
      tokenManager.setToken(TokenStore(
        accessToken: 'arrived-access',
        refreshToken: 'arrived-refresh',
      ));
      return ResponseBody.fromString('unauthorized', 401);
    });

    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    expect(refreshCalls, 0);
    expect(retried, isFalse);
  });

  test('refresh Dio receives authHeader even if failed request headers lack it',
      () async {
    late RequestOptions refreshRequest;

    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    dio.interceptors.add(
      DioRefreshInterceptor(
        tokenManager: tokenManager,
        shouldRefresh: (response) => response?.statusCode == 401,
        isTokenValid: (_) => true,
        // Simulate a path where auth lands only via authHeader merge at refresh.
        authHeader: (store) => {
          'authorization': 'Bearer ${store.accessToken}',
          'x-refresh-token': store.refreshToken ?? '',
        },
        retryInterceptors: [_OkRetryInterceptor()],
        onRefresh: (refreshDio, store) async {
          refreshDio.httpClientAdapter = _CallbackAdapter((options) {
            refreshRequest = options;
            return ResponseBody.fromString(
              '{"ok":true}',
              200,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            );
          });
          await refreshDio.get('https://accounts.example.com/api/users/refresh');
          return TokenStore(
            accessToken: 'new-a',
            refreshToken: 'new-r',
          );
        },
      ),
    );
    dio.httpClientAdapter = _CallbackAdapter(
      (_) => ResponseBody.fromString('unauthorized', 401),
    );

    await dio.get('/protected');

    expect(refreshRequest.headers['authorization'], 'Bearer old-access');
    expect(refreshRequest.headers['x-refresh-token'], 'old-refresh');
  });
}

class _CallbackAdapter implements HttpClientAdapter {
  _CallbackAdapter(this._onFetch);

  final ResponseBody Function(RequestOptions options) _onFetch;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return _onFetch(options);
  }
}
