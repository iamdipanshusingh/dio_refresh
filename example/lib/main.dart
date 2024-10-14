import 'package:dio/dio.dart';
import 'package:dio_refresh/dio_refresh.dart';

void main() {
  final dio = Dio();

  // Define the TokenManager instance.
  final tokenManager = TokenManager.instance;
  tokenManager.setToken(
    TokenStore(
      accessToken: "authToken",
      refreshToken: "refreshToken",
    ),
  );

  // Add the DioRefreshInterceptor.
  dio.interceptors.add(DioRefreshInterceptor(
    tokenManager: tokenManager,
    authHeader: (tokenStore) {
      if (tokenStore.accessToken == null) {
        return {};
      }
      return {
        'Authorization': 'Bearer ${tokenStore.accessToken}',
      };
    },
    shouldRefresh: (response) =>
        response?.statusCode == 401 || response?.statusCode == 403,
    onRefresh: (dio, tokenStore) async {
      final response = await dio.post('/refresh', data: {
        'refresh_token': tokenStore.refreshToken,
      });
      return TokenStore(
        accessToken: response.data['accessToken'],
        refreshToken: response.data['refreshToken'],
      );
    },
  ));
}
