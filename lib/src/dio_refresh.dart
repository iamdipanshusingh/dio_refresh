import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dio_refresh/dio_refresh.dart';

typedef OnRefreshCallback = Future<TokenStore> Function(Dio, TokenStore);
typedef ShouldRefreshCallback = bool Function(Response?);
typedef TokenHeaderCallback = Map<String, String> Function(TokenStore);

class DioRefreshInterceptor extends Interceptor {
  final TokenManager tokenManager;

  final OnRefreshCallback onRefresh;

  final ShouldRefreshCallback shouldRefresh;

  final TokenHeaderCallback authHeader;

  DioRefreshInterceptor({
    required this.tokenManager,
    required this.onRefresh,
    required this.shouldRefresh,
    required this.authHeader,
  });

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

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    if (tokenManager.isRefreshing.value) {
      await _checkForRefreshToken();
    } else {
      handler.next(response);
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    final response = err.response;

    if (shouldRefresh(response)) {
      if (tokenManager.isRefreshing.value) {
        await _checkForRefreshToken();
      } else {
        try {
          tokenManager.isRefreshing.value = true;

          final headers = {...request.headers};
          headers.remove("content-length");

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

          tokenManager.isRefreshing.value = false;
          tokenManager.setToken(refreshResponse);

          final header = authHeader(tokenManager.tokenStore);
          request.headers = {...request.headers, ...header};

          final dio = Dio(BaseOptions(baseUrl: request.baseUrl));
          final res = await dio.request(
            request.path,
            cancelToken: request.cancelToken,
            data: request.data,
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
      }
    } else {
      handler.next(err);
    }
  }

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
}
