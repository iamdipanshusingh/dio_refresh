# Dio Refresh Interceptor

[![pub package](https://img.shields.io/pub/v/dio_refresh.svg)](https://pub.dev/packages/dio_refresh)
![license](https://img.shields.io/github/license/iamdipanshusingh/dio_refresh.svg)

A Dart package that provides an interceptor for handling automatic token refresh in `Dio` HTTP client requests. It simplifies the process of managing access and refresh tokens, ensuring that your API requests stay authenticated, even when the access token expires.

## Features

- **Automatic Token Refresh**: Automatically refreshes the access token when it expires using a custom refresh callback.
- **Customizable**: Define custom logic for determining when a token refresh is needed and how headers are generated.
- **Singleton Token Manager**: A singleton `TokenManager` class for easy token storage and retrieval.
- **Seamless Integration**: Designed for use with the `Dio` HTTP client package.

## Installation

Add the following dependency to your `pubspec.yaml` file:

```yaml
dependencies:
  dio: ^5.0.0
  dio_refresh: ^1.0.0
  flutter:
    sdk: flutter
```

Then, run:

```bash
flutter pub get
```

## Getting Started

### Setup `DioRefreshInterceptor`

To use the `DioRefreshInterceptor`, you'll need to define the following callbacks:

- `OnRefreshCallback`: Handles the logic for refreshing the access token.
- `ShouldRefreshCallback`: Determines whether a response requires a token refresh.
- `TokenHeaderCallback`: Generates headers with the access token.

### Example

```dart
import 'package:dio/dio.dart';
import 'package:dio_refresh/dio_refresh.dart';

void main() {
  final dio = Dio();

  // Define the TokenManager instance.
  final tokenManager = TokenManager.instance;
  tokenManager.setToken(
    TokenStore(
      accessToken: authToken,
      refreshToken: refreshToken,
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
```

### TokenManager Usage

The `TokenManager` class is used to manage your access and refresh tokens.

```dart
// Retrieve the singleton instance of TokenManager.
final tokenManager = TokenManager.instance;

// Set new tokens after refreshing.
tokenManager.setToken(TokenStore(
  accessToken: 'newAccessToken',
  refreshToken: 'newRefreshToken',
));

// Access the current access token.
print(tokenManager.accessToken);
```

## API Reference

### `DioRefreshInterceptor`

- **`DioRefreshInterceptor`**: A custom interceptor for handling token refresh logic.
    - `tokenManager`: Instance of `TokenManager` to manage tokens.
    - `authHeader`: Callback to generate authorization headers.
    - `shouldRefresh`: Callback to determine if a refresh is needed.
    - `onRefresh`: Callback to handle the refresh logic and return a new `TokenStore`.
    - `isTokenValid`: Optional callback to validate if a token is still valid.

### `TokenManager`

- **`TokenManager`**: A singleton class to manage tokens.
    - `setToken(TokenStore tokenStore)`: Updates the stored access and refresh tokens.
    - `accessToken`: Returns the current access token.
    - `refreshToken`: Returns the current refresh token.
    - `isRefreshing`: A `ValueNotifier` that indicates whether a refresh is in progress.

### `typedef` Callbacks

- **`OnRefreshCallback`**: `Future<TokenStore> Function(Dio, TokenStore)`
    - Handles the token refresh logic.
- **`ShouldRefreshCallback`**: `bool Function(Response?)`
    - Determines if a token refresh is required.
- **`TokenHeaderCallback`**: `Map<String, String> Function(TokenStore)`
    - Generates authorization headers for requests.
- **`IsTokenValidCallback`**: `bool Function(String)`
    - Validates if a token is still valid.
    - Default implementation checks if the JWT token is not expired.
    - Called if [shouldRefresh] returns `true`.
    - Can be customized to implement different token validation strategies.

### Example with Custom Token Validation

```dart
final dio = Dio();
dio.interceptors.add(DioRefreshInterceptor(
  tokenManager: tokenManager,
  onRefresh: onRefresh,
  shouldRefresh: shouldRefresh,
  authHeader: authHeader,
  isTokenValid: (token) {
    // Implement custom token validation logic
    try {
      final decodedToken = JwtDecoder.decode(token);
      // Add additional validation checks here
      return !JwtDecoder.isExpired(token) && 
             decodedToken['custom_claim'] == 'expected_value';
    } catch (_) {
      return false;
    }
  },
));
```

## Contributing

Contributions are welcome! Feel free to open issues or submit a pull request on GitHub. For significant changes, please open an issue first to discuss what you would like to change.
