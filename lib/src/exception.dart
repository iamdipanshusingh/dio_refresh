/// A custom exception used to indicate a failure during the token refresh process.
///
/// `RefreshTokenException` is thrown when an error occurs while attempting
/// to refresh an expired access token. This can be used to handle specific
/// refresh-related errors in your code, allowing for more precise error
/// handling and debugging.
///
/// Example usage:
/// ```dart
/// try {
///   // Trigger the token refresh process.
/// } catch (e) {
///   if (e is RefreshTokenException) {
///     // Handle the refresh token error, such as logging out the user or showing an error message.
///   }
/// }
/// ```
class RefreshTokenException implements Exception {}
