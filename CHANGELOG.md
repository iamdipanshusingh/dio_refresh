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
