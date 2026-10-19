## 2.0.0

* **Breaking:** `shouldRefresh` and `isTokenValid` now have separate responsibilities. If you relied on refreshing after arbitrary errors with an expired token, include that condition in your `shouldRefresh` callback.
  * `shouldRefresh` is now the only gate for refreshing on error. Previously, any failed request (500s, timeouts, connection errors, ...) also triggered a refresh and retry whenever `isTokenValid` reported the current token as invalid, even if `shouldRefresh` returned `false`, which could resend non-idempotent requests (e.g. a `POST` that returned 500). This reverts part of 1.0.6; revoked tokens are still handled, since the server's 401 matches `shouldRefresh`.
  * `isTokenValid` is now checked in `onRequest`, before a request is sent. Expired tokens are refreshed proactively (deduplicated across concurrent requests via `TokenManager.refreshLock`). If that refresh fails, the request is still sent with the existing token, and `onRefreshFailedCallback` is invoked.
  * The default `isTokenValid` now treats tokens that cannot be decoded as a JWT as valid. Previously, opaque tokens were always considered invalid, so every failed request triggered a refresh.
* Fixed the docs for `isTokenValid`, which said it was called when `shouldRefresh` returned `true` (it was actually called when it returned `false`).

## 1.2.3

* Fixed a race where a request sent without an access token could still enter the
  refresh/retry path after a later `TokenManager.setToken` (for example login, or
  another client syncing the singleton). Refresh is now gated on the access token
  captured at send time, not only the current `TokenManager` value.
* Refresh Dio seeding now re-applies `authHeader` from the current `TokenStore`,
  so the refresh call is not left tokenless when the failed request lacked auth
  headers.

## 1.2.2

* Concurrent 401s now share a single refresh via `Lock.synchronized` on `TokenManager`, so `onRefresh` runs only once even across multiple `Dio` / interceptor instances.
* Replaced access-token string comparison with a `tokenGeneration` counter: waiters skip a second refresh after the lock is released even when the server returns the same token strings.

## 1.2.1

* Fixed a race condition where requests already in flight with an expired token could each trigger a new `onRefresh` after an earlier refresh had already completed, causing duplicate refresh calls (and `401`/`503` failures with rotating refresh tokens). Each request now records the access token it was sent with and skips the refresh if the token has already been rotated, retrying directly instead.
* Fixed refresh failures not propagating to concurrent requests: the in-flight refresh now resolves to a success/failure result that every waiting `onError` handler observes, so a failed refresh is forwarded to all of them instead of retrying with an invalid token.

## 1.2.0

* **Breaking:** Removed time-based refresh throttling and the `throttleDuration` option added in 1.1.0. Upgrade by deleting any `throttleDuration` argument from your setup.
* Refresh is serialized with an in-flight `Future` (`_refreshFuture`): the first failure starts `onRefresh`; any other concurrent `onError` handlers await that same future instead of starting another refresh.
* Outgoing requests wait their turn: `onRequest` awaits `_refreshFuture` before applying `authHeader`, so new calls do not attach a stale token while a refresh is still running.
* After the shared refresh completes, `_refreshFuture` is cleared so a later auth failure can start a new refresh cycle.

## 1.1.0

* Fixed `onRefresh` being called multiple times simultaneously, resulting in future API failure
* Added configurable `throttleDuration` to control token refresh throttling window (default: `800ms`)

## 1.0.8

* Fixed `Bad state: handler already called` error when token refresh fails — handler was being called twice due to fall-through after the synchronized block

## 1.0.7

* Added support for providing an `OnRefreshFailedCallback` to handle refresh failures

## 1.0.6

* Fix: Refresh is now triggered when either the server requests it (shouldRefresh) or the token is
  locally expired. Previously both conditions were required, causing refresh to be skipped in
  revoked-token scenarios

## 1.0.5

* Added retry interceptors

## 1.0.4

* Fixed form data being submitted twice error on request retry
* Added custom token validation callback

## 1.0.3

* Fixed error handling for `isRefreshing` deadlock
* Fixed `onRefresh` being called multiple times simultaneously

## 1.0.2

* Fixed refresh being called even if token is null
* Fixed isRefreshing deadlock, causing APIs to never resolve

## 1.0.1

* Fixed changelog

## 1.0.0

* Fixed bulk API call handling to prevent failures.

## 0.0.1

* Initial release.
