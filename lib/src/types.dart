import 'package:dio/dio.dart';
import 'package:dio_refresh/dio_refresh.dart';

/// A callback function that handles the token refresh process.
///
/// This function is called when a token refresh is required, such as when the
/// access token has expired. It receives the following parameters:
///
/// - [Dio]: The `Dio` instance used to make the refresh request.
/// - [TokenStore]: The current `TokenStore` containing the existing access and refresh tokens.
///
/// The function should return a `Future` that resolves with a new `TokenStore`
/// containing the updated access and refresh tokens.
///
/// Example:
/// ```dart
/// Future<TokenStore> refreshToken(Dio dio, TokenStore tokenStore) async {
///   final response = await dio.post('/refresh', data: {
///     'refresh_token': tokenStore.refreshToken,
///   });
///   return TokenStore(
///     accessToken: response.data['accessToken'],
///     refreshToken: response.data['refreshToken'],
///   );
/// }
/// ```
typedef OnRefreshCallback = Future<TokenStore> Function(Dio, TokenStore);

/// A callback function that determines whether a response should trigger a token refresh.
///
/// This function is used to evaluate if the given [Response] indicates that the
/// access token is expired or invalid and a refresh is needed. If the function
/// returns `true`, the token refresh process will be initiated.
///
/// The [Response] parameter can be `null`, in which case the function should
/// handle that scenario appropriately.
///
/// Example:
/// ```dart
/// bool shouldRefresh(Response? response) {
///   return response?.statusCode == 401 || response?.statusCode == 403;
/// }
/// ```
typedef ShouldRefreshCallback = bool Function(Response?);

/// A callback function that generates the authorization headers for API requests.
///
/// This function is used to create the headers required for authenticated requests,
/// based on the current state of the tokens. It receives the [TokenStore] containing
/// the current access and refresh tokens, and returns a `Map<String, String>` with
/// the necessary headers.
///
/// Example:
/// ```dart
/// Map<String, String> tokenHeader(TokenStore tokenStore) {
///   if (tokenStore.accessToken != null) {
///     return {
///       'Authorization': 'Bearer ${tokenStore.accessToken}',
///     };
///   }
///   return {};
/// }
/// ```
typedef TokenHeaderCallback = Map<String, String> Function(TokenStore);
