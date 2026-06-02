## 1.4.0

- Modernize to Dart 3 (`sdk: '>=3.0.0 <4.0.0'`); fresh `dart pub get`.
- Replace `pedantic` with `package:lints/recommended.yaml`; `dart analyze
  --fatal-infos` is clean. Idiomatic clean-ups (for-loops over `forEach`
  literals, string interpolation, `Object` parameters on `operator ==`,
  explicit types) with no public-API or behaviour changes.
- Bug fixes (behaviour-preserving for valid inputs, correctness fixes for
  the previously-broken paths):
  - UDP announce response: `complete` (seeders) and `incomplete` (leechers)
    were read from the wrong offsets (swapped) per BEP15; now correct.
  - HTTP tracker: `tracker id` (and HTTP-scrape `name`) come back from bencode
    as raw bytes and were assigned straight into `String?` fields, throwing a
    runtime `TypeError`; they are now decoded to `String`.
  - HTTP tracker dictionary-model peer list: `ip` is delivered as raw bytes by
    bencode and broke `InternetAddress.tryParse`; it is now decoded first.
  - `Tracker` announce interval: `math.min(interval!, minInterval!)`
    force-unwrapped the optional `min interval`, throwing when it is absent
    (the common case, e.g. UDP); it now falls back gracefully.
  - UDP announce response IPv6 branch parsed peers with `parseIPv4Addresses`;
    now uses `parseIPv6Addresses`.
  - UDP/`ByteData` views now respect `offsetInBytes` of the datagram buffer.
- Add a unit-test suite (round-trip UDP connect/announce/scrape packet
  build + parse, HTTP announce/scrape bencode parsing incl. compact and
  dict peers, failure-reason, edge cases) and a GitHub Actions CI workflow.

## 1.0.0

- Initial version

## 1.1.0

- Change the interface

## 1.3.1

- Change the tracker interfaces and add a new dependency

## 1.3.4
- Add IPv6 support
- Make tracker and scrape can re-try
- Change Readme and example
- Delete useless files

## 1.3.6
- Fix a http tracker bug

## 1.3.11
- Remove 'timeout' retry future.
- Add 'Error happen' retry future.
- Change HttpTracker

## 1.3.12
- Add 'complete' method