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

  /// A callback to determine whether a failed response should trigger a token refresh.
  ///
  /// The `shouldRefresh` function checks if the response status indicates that a refresh
  /// is necessary (e.g., status code 401 or 403). Returns `true` if a refresh should occur.
  ///
  /// This is the only gate for refreshing on error: when it returns `false`, the
  /// error is forwarded unchanged and no refresh or retry happens.
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
  /// This is called in [onRequest], before a request is sent. If it returns
  /// `false`, the token is refreshed proactively and the request goes out with
  /// the new token. It is not consulted when a request fails; that decision
  /// belongs to [shouldRefresh].
  ///
  /// If not specified, the default treats a JWT as invalid once it has expired.
  /// Tokens that cannot be decoded as a JWT (e.g. opaque tokens) are treated as
  /// valid, leaving the server's response and [shouldRefresh] to decide.
  late final IsTokenValidCallback isTokenValid;

  /// Optional callback invoked when [onRefresh] throws.
  ///
  /// This can be used to log refresh failures or trigger cleanup (for example,
  /// clearing local session state). The original [DioException] is still passed
  /// forward to Dio's error chain after this callback is executed.
  late final OnRefreshFailedCallback? onRefreshFailedCallback;

  /// The key under which the [TokenManager.tokenGeneration] at request time is
  /// stored in [RequestOptions.extra].
  ///
  /// This lets [onError] detect whether tokens were already rotated since the
  /// failing request was sent, so it can retry directly instead of triggering
  /// a redundant refresh — even when the refreshed token string is unchanged.
  static const String _sentTokenGenerationKey =
      '__dio_refresh_token_generation__';

  /// The key under which the access token used to build a request is stored in
  /// [RequestOptions.extra].
  ///
  /// Refresh/retry is only attempted when this value was non-null at send time,
  /// so a later [TokenManager.setToken] (login / another client) cannot open the
  /// refresh gate for a request that left without auth headers.
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
  /// Before each request is sent, any in-flight refresh (held by
  /// [TokenManager.refreshLock]) is awaited. If the current access token fails
  /// [isTokenValid], it is refreshed proactively. Then the necessary
  /// authentication headers are added using the [authHeader] callback.
  ///
  /// If a proactive refresh fails, the request is still sent with the existing
  /// token; the server remains the authority on whether it is accepted.
  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Wait out any refresh currently holding the lock.
    await tokenManager.refreshLock.synchronized(() {});

    final accessToken = tokenManager.accessToken;
    if (accessToken != null && !isTokenValid(accessToken)) {
      await _refreshTokens(options, tokenManager.tokenGeneration);
    }

    final header = authHeader(tokenManager.tokenStore);
    final headers = {...options.headers, ...header};
    final extra = {
      ...options.extra,
      _sentTokenGenerationKey: tokenManager.tokenGeneration,
      _sentAccessTokenKey: tokenManager.accessToken,
    };

    super.onRequest(options.copyWith(headers: headers, extra: extra), handler);
  }

  /// Intercepts errors to determine if a token refresh is needed.
  ///
  /// When an error response matches the [shouldRefresh] condition (e.g., 401),
  /// the interceptor triggers the `onRefresh` callback to obtain a new token
  /// and retries the original request with the updated token. Errors that do
  /// not match [shouldRefresh] are forwarded unchanged.
  ///
  /// Concurrent failures serialize on [TokenManager.refreshLock]: the first
  /// request runs [onRefresh]; others wait, see that the generation already
  /// advanced, and retry with the refreshed tokens.
  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    final response = err.response;
    // Access token this request was actually sent with (captured in onRequest).
    // A later setToken on the singleton TokenManager must not cause an
    // unauthenticated in-flight request to refresh/retry with empty auth headers.
    final sentToken = request.extra[_sentAccessTokenKey] as String?;
    final sentGeneration = request.extra[_sentTokenGenerationKey] as int?;
    // Only refresh/retry when THIS request left with an access token. Tokens
    // appearing on TokenManager after send (login / another request's setToken)
    // must not open the gate for a request that never had auth headers.
    final shouldAttemptRefresh = sentToken != null &&
        tokenManager.accessToken != null &&
        shouldRefresh(response);

    if (shouldAttemptRefresh) {
      final alreadyRefreshed = sentGeneration != null &&
          tokenManager.tokenGeneration != sentGeneration;

      if (!alreadyRefreshed) {
        final refreshed = await _refreshTokens(request, sentGeneration);
        if (!refreshed) {
          handler.next(err);
          return;
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

  /// Runs [onRefresh] under [TokenManager.refreshLock] and stores the result.
  ///
  /// Skips the refresh if tokens were already rotated past [sentGeneration]
  /// while waiting for the lock. Returns `true` if fresh tokens are available,
  /// `false` if [onRefresh] threw.
  Future<bool> _refreshTokens(RequestOptions request, int? sentGeneration) {
    return tokenManager.refreshLock.synchronized(() async {
      // Another request may have refreshed while we waited for the lock.
      if (sentGeneration != null &&
          tokenManager.tokenGeneration != sentGeneration) {
        return true;
      }

      try {
        // Prefer current TokenManager credentials over whatever is on the
        // request, so refresh never goes out tokenless when tokens are
        // available.
        final headers = {
          ...request.headers,
          ...authHeader(tokenManager.tokenStore),
        };
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
  }

  /// The default callback for the [IsTokenValidCallback].
  ///
  /// A JWT is valid until its expiration time has passed. Tokens that cannot be
  /// decoded as a JWT are treated as valid, since their expiry is unknown here.
  bool _isAccessTokenValid(String accessToken) {
    try {
      return !JwtDecoder.isExpired(accessToken);
    } catch (_) {
      return true;
    }
  }
}
