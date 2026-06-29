import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_refresh/dio_refresh.dart';
import 'package:jwt_decoder/jwt_decoder.dart';

/// A custom `Dio` interceptor that handles token refresh logic for authenticated API requests.
///
/// The `DioRefreshInterceptor` class is used to automatically refresh access tokens
/// when they expire. It listens for specific response status codes (like 401 or 403),
/// triggers the token refresh process, and retries the failed request with the new token.
///
/// Example usage:
/// ```dart
/// final dio = Dio();
/// dio.interceptors.add(DioRefreshInterceptor(
///   tokenManager: tokenManager,
///   onRefresh: (dio, tokenStore) async {
///     // Implement token refresh logic here.
///   },
///   shouldRefresh: (response) => response?.statusCode == 401,
///   authHeader: (tokenStore) => {
///     'Authorization': 'Bearer ${tokenStore.accessToken}',
///   },
/// ));
/// ```
///
/// This example shows how to add the interceptor to a `Dio` instance and define
/// the callback for token refresh.
class DioRefreshInterceptor extends Interceptor {
  /// Manages the current token state and refresh process.
  final TokenManager tokenManager;

  /// A callback that defines how to refresh the token.
  ///
  /// The `onRefresh` function is called when a refresh is needed, passing the `Dio` instance
  /// and the current `TokenStore`. It should return a `Future` that resolves with a new `TokenStore`
  /// containing updated tokens.
  final OnRefreshCallback onRefresh;

  /// A callback to determine whether a response should trigger a token refresh.
  ///
  /// The `shouldRefresh` function checks if the response status indicates that a refresh
  /// is necessary (e.g., status code 401 or 403). Returns `true` if a refresh should occur.
  final ShouldRefreshCallback shouldRefresh;

  /// A callback that returns the headers required for authentication.
  ///
  /// The `authHeader` function generates headers using the `TokenStore` (e.g., Authorization
  /// headers). These headers are added to the request before it is sent.
  final TokenHeaderCallback authHeader;

  /// A list of interceptors to be added to the `Dio` instance used for retrying requests.
  ///
  /// This allows you to add custom interceptors, such as for logging, to the `Dio` instance
  /// that handles the request retry process.
  ///
  /// **Note:** Do not add another `DioRefreshInterceptor` to this list, as it may cause
  /// an infinite loop. An assertion is in place to prevent this during development.
  final List<Interceptor>? retryInterceptors;

  /// An optional callback to check if a token is valid.
  ///
  /// This is called if [shouldRefresh] returns `true`.
  /// If not specified, the default is to check that the token can be decoded
  /// and has not expired.
  late final IsTokenValidCallback isTokenValid;

  /// Optional callback invoked when [onRefresh] throws.
  ///
  /// This can be used to log refresh failures or trigger cleanup (for example,
  /// clearing local session state). The original [DioException] is still passed
  /// forward to Dio's error chain after this callback is executed.
  late final OnRefreshFailedCallback? onRefreshFailedCallback;

  /// The refresh work started from [onError], or `null` when idle.
  ///
  /// Multiple failing requests can enter [onError] at once; they all await this
  /// same [Future] so only one [onRefresh] runs and the rest wait for it to finish.
  /// The future resolves to `true` when the refresh succeeded and `false` when it
  /// failed, so every waiting request observes the same outcome.
  /// Cleared to `null` after the refresh completes so a later failure can start a new cycle.
  Future<bool>? _refreshFuture;

  /// The key under which the access token used to build a request is stored in
  /// [RequestOptions.extra].
  ///
  /// This lets [onError] detect whether the token has already been rotated since
  /// the failing request was sent, so it can retry directly instead of triggering
  /// a redundant refresh.
  static const String _sentAccessTokenKey = '__dio_refresh_access_token__';

  /// Creates an instance of `DioRefreshInterceptor`.
  ///
  /// The interceptor requires a [tokenManager] to handle the token state, an [onRefresh]
  /// callback to manage the refresh process, a [shouldRefresh] callback to determine when
  /// to refresh, and an [authHeader] callback to provide the necessary authentication headers.
  /// An optional [isTokenValid] callback can be provided to customize the token validation process.
  /// Use [onRefreshFailedCallback] to handle side effects when refresh throws.
  DioRefreshInterceptor({
    required this.tokenManager,
    required this.onRefresh,
    required this.shouldRefresh,
    required this.authHeader,
    this.onRefreshFailedCallback,
    this.retryInterceptors,
    IsTokenValidCallback? isTokenValid,
  }) {
    assert(
      retryInterceptors?.any((i) => i is DioRefreshInterceptor) != true,
      'Cannot add a DioRefreshInterceptor to the retryInterceptors, as it may cause an infinite loop.',
    );
    this.isTokenValid = isTokenValid ?? _isAccessTokenValid;
  }

  /// Intercepts outgoing requests to add authorization headers.
  ///
  /// Before each request is sent, `_refreshFuture` ensures that any ongoing
  /// token refresh process is completed. Then, it adds the necessary authentication
  /// headers using the [authHeader] callback.
  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    await _refreshFuture;

    final header = authHeader(tokenManager.tokenStore);
    final headers = {...options.headers, ...header};
    final extra = {
      ...options.extra,
      _sentAccessTokenKey: tokenManager.accessToken,
    };

    super.onRequest(options.copyWith(headers: headers, extra: extra), handler);
  }

  /// Intercepts errors to determine if a token refresh is needed.
  ///
  /// When an error response matches the [shouldRefresh] condition (e.g., 401),
  /// the interceptor triggers the `onRefresh` callback to obtain a new token
  /// and retries the original request with the updated token.
  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    final response = err.response;
    bool shouldRefreshToken = shouldRefresh(response) ||
        (tokenManager.accessToken != null &&
            !isTokenValid(tokenManager.accessToken!));

    if (tokenManager.accessToken != null && shouldRefreshToken) {
      // The access token this request was sent with. If the current token no
      // longer matches, another request already refreshed it while this one was
      // in flight, so we can skip the refresh entirely and just retry.
      final sentToken = request.extra[_sentAccessTokenKey] as String?;
      final alreadyRefreshed =
          sentToken != null && tokenManager.accessToken != sentToken;

      if (!alreadyRefreshed) {
        final inFlight = _refreshFuture;
        if (inFlight != null) {
          final refreshed = await inFlight;
          if (!refreshed) {
            handler.next(err);
            return;
          }
        } else {
          final refreshFuture = Future(() async {
            try {
              final headers = {...request.headers};
              headers.remove(HttpHeaders.contentLengthHeader);

              final refreshDio = Dio(BaseOptions(
                sendTimeout: request.sendTimeout,
                receiveTimeout: request.receiveTimeout,
                extra: request.extra,
                headers: headers,
                responseType: request.responseType,
                contentType: request.contentType,
                validateStatus: request.validateStatus,
                receiveDataWhenStatusError: request.receiveDataWhenStatusError,
                followRedirects: request.followRedirects,
                maxRedirects: request.maxRedirects,
                requestEncoder: request.requestEncoder,
                responseDecoder: request.responseDecoder,
                listFormat: request.listFormat,
              ));
              final refreshResponse = await onRefresh(
                refreshDio,
                tokenManager.tokenStore,
              );

              tokenManager.setToken(refreshResponse);
              return true;
            } catch (e) {
              onRefreshFailedCallback?.call(e);
              return false;
            }
          });
          _refreshFuture = refreshFuture;
          final refreshed = await refreshFuture;
          _refreshFuture = null;

          if (!refreshed) {
            handler.next(err);
            return;
          }
        }
      }

      try {
        final header = authHeader(tokenManager.tokenStore);
        request.headers = {...request.headers, ...header};

        final dio = Dio(BaseOptions(baseUrl: request.baseUrl));
        if (retryInterceptors != null) {
          dio.interceptors.addAll(retryInterceptors!);
        }
        final res = await dio.request(
          request.path,
          cancelToken: request.cancelToken,
          // Clone FormData to avoid an error about submitting it twice.
          data: request.data is FormData ? request.data.clone() : request.data,
          onReceiveProgress: request.onReceiveProgress,
          onSendProgress: request.onSendProgress,
          queryParameters: request.queryParameters,
          options: Options(
            method: request.method,
            sendTimeout: request.sendTimeout,
            receiveTimeout: request.receiveTimeout,
            extra: request.extra,
            headers: request.headers,
            responseType: request.responseType,
            contentType: request.contentType,
            validateStatus: request.validateStatus,
            receiveDataWhenStatusError: request.receiveDataWhenStatusError,
            followRedirects: request.followRedirects,
            maxRedirects: request.maxRedirects,
            requestEncoder: request.requestEncoder,
            responseDecoder: request.responseDecoder,
            listFormat: request.listFormat,
          ),
        );
        handler.resolve(res);
      } on DioException catch (e) {
        handler.next(e);
      }
    } else {
      handler.next(err);
    }
  }

  /// The default callback for the [IsTokenValidCallback].
  ///
  /// The token is valid if it can be decoded and the expiration time has not passed.
  bool _isAccessTokenValid(String accessToken) {
    try {
      return !JwtDecoder.isExpired(accessToken);
    } catch (_) {}
    return false;
  }
}
