/// A class that holds authentication tokens for API requests.
///
/// The `TokenStore` class is designed to store the `accessToken` and
/// `refreshToken` needed for making authenticated API calls. It serves
/// as a container for these tokens and is used during the process of
/// refreshing access tokens when they expire.
///
/// Example usage:
/// ```dart
/// // Creating an instance of TokenStore.
/// final tokenStore = TokenStore(
///   accessToken: 'your_access_token',
///   refreshToken: 'your_refresh_token',
/// );
///
/// // Accessing tokens.
/// print('Access Token: ${tokenStore.accessToken}');
/// print('Refresh Token: ${tokenStore.refreshToken}');
/// ```
class TokenStore {
  /// The access token used for authenticated API requests.
  ///
  /// This token is typically a JWT that authorizes access to protected endpoints.
  /// It may be `null` if not yet available or expired.
  final String? accessToken;

  /// The refresh token used to obtain a new access token when the
  /// current one expires.
  ///
  /// This token allows the application to refresh the `accessToken`
  /// without requiring the user to re-authenticate. It may also be
  /// `null` if not available.
  final String? refreshToken;

  /// Creates an instance of `TokenStore` with the provided
  /// [accessToken] and [refreshToken].
  ///
  /// Both [accessToken] and [refreshToken] are required parameters,
  /// though they may be `null` depending on the state of authentication.
  TokenStore({
    required this.accessToken,
    required this.refreshToken,
  });
}
