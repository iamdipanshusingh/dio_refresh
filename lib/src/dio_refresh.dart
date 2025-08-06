import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_refresh/dio_refresh.dart';
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:synchronized/extension.dart';

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

  /// Creates an instance of `DioRefreshInterceptor`.
  ///
  /// The interceptor requires a [tokenManager] to handle the token state, an [onRefresh]
  /// callback to manage the refresh process, a [shouldRefresh] callback to determine when
  /// to refresh, and an [authHeader] callback to provide the necessary authentication headers.
  /// An optional [isTokenValid] callback can be provided to customize the token validation process.
  DioRefreshInterceptor({
    required this.tokenManager,
    required this.onRefresh,
    required this.shouldRefresh,
    required this.authHeader,
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
  /// Before each request is sent, `_checkForRefreshToken` ensures that any ongoing
  /// token refresh process is completed. Then, it adds the necessary authentication
  /// headers using the [authHeader] callback.
  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    await _checkForRefreshToken();

    final header = authHeader(tokenManager.tokenStore);
    final headers = {...options.headers, ...header};

    super.onRequest(options.copyWith(headers: headers), handler);
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

    if (tokenManager.accessToken != null && shouldRefresh(response)) {
      if (tokenManager.isRefreshing.value) {
        await _checkForRefreshToken();
      } else {
        await synchronized(() async {
          bool isAccessTokenValid = isTokenValid(tokenManager.accessToken!);
          if (!isAccessTokenValid) {
            try {
              tokenManager.isRefreshing.value = true;

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
              tokenManager.isRefreshing.value = false;
            } catch (e) {
              tokenManager.isRefreshing.value = false;
              handler.next(err);
            }
          }
        });
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

  /// A helper method to wait for any ongoing token refresh process to complete.
  ///
  /// The `_checkForRefreshToken` method creates a `Completer` that completes once
  /// the `isRefreshing` state of the `tokenManager` changes to `false`, indicating
  /// that the refresh process has finished.
  Future<void> _checkForRefreshToken() {
    Completer<void> completer = Completer();

    void listener() {
      if (!tokenManager.isRefreshing.value) {
        completer.complete();
        tokenManager.isRefreshing.removeListener(listener);
      }
    }

    if (tokenManager.isRefreshing.value) {
      tokenManager.isRefreshing.addListener(listener);
    } else {
      completer.complete();
    }

    return completer.future;
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
