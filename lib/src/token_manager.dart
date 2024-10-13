import 'package:dio_refresh/dio_refresh.dart';
import 'package:flutter/foundation.dart';

/// A singleton class to manage access and refresh tokens for authentication.
///
/// The `TokenManager` handles storing, retrieving, and updating access tokens
/// and refresh tokens. It also provides a `ValueNotifier` to track the state
/// of the token refresh process, enabling reactive behavior in Flutter apps.
///
/// This class uses the singleton pattern to ensure a single instance throughout
/// the application, providing a central point of access for token management.
///
/// Example:
/// ```dart
/// final tokenManager = TokenManager.instance;
/// tokenManager.setToken(TokenStore(
///   accessToken: 'newAccessToken',
///   refreshToken: 'newRefreshToken',
/// ));
/// print(tokenManager.accessToken);
/// ```

class TokenManager {
  String? _refreshToken;
  String? _accessToken;

  // Private constructor for the singleton instance.
  static final TokenManager _instance = TokenManager._internal();

  TokenManager._internal();

  /// Retrieves the singleton instance of `TokenManager`.
  static TokenManager get instance => _instance;

  /// Returns the current refresh token.
  String? get refreshToken => _refreshToken;

  /// Returns the current access token.
  String? get accessToken => _accessToken;

  /// Retrieves the current tokens as a `TokenStore` object.
  TokenStore get tokenStore => TokenStore(
        accessToken: _accessToken,
        refreshToken: _refreshToken,
      );

  /// A `ValueNotifier` that tracks whether the refresh process is active.
  ///
  /// This is useful for observing the refresh state and triggering actions
  /// when a refresh is in progress or has completed.
  final ValueNotifier<bool> _isRefreshing = ValueNotifier(false);

  /// Provides access to the `ValueNotifier` indicating whether a refresh is in progress.
  ValueNotifier<bool> get isRefreshing => _isRefreshing;

  /// Updates the stored tokens with a new `TokenStore`.
  ///
  /// This method should be called after a successful token refresh to update
  /// the access and refresh tokens with new values.
  ///
  /// [tokenStore] - The new `TokenStore` containing the updated tokens.
  void setToken(TokenStore tokenStore) {
    _accessToken = tokenStore.accessToken;
    _refreshToken = tokenStore.refreshToken;
  }
}
