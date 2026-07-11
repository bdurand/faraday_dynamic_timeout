# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.1.1

### Added

- The middleware now fails open on any Redis error: instead of raising and taking down HTTP traffic, the request is made using the highest configured timeout without throttling.

### Fixed

- Padded the TTL used to clean up orphaned Redis entries for throttle slots and request counters. Previously the TTL was set to the bucket timeout, but a request's total wall time can legitimately exceed the timeout (adapters apply it to the open/read/write phases individually), so slots could expire and be reclaimed while requests were still in flight, allowing the concurrency limit to be exceeded.
- A `Restrainer::ThrottledError` raised from within the request itself (e.g. from a nested middleware) is no longer mistaken for a full bucket. Previously such an error would cause the request to be retried on the next bucket, executing the HTTP request a second time.
- Made bucket configuration memoization safe when the configuration array is mutated concurrently by another thread.
- Added missing `require "securerandom"`, which previously only worked because a dependency loaded it.

### Documentation

- Documented the `RequestInfo` fields, the behavior of `timed_out?` with respect to connection-level timeouts, the fact that `:callback` runs inline and can mask the request result if it raises, and the streaming/parallel adapter limitations.

### Removed

- Removed unused internal `Strategy` class.

## 1.1.0

### Added

- Add `before_request` option on middleware to allow making custom changes to the request based on the timeout value being used.

## 1.0.0

### Added

- Initial release
