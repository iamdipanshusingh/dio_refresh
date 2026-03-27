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
