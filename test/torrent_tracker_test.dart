import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bencode_dart/bencode_dart.dart' as bencode;
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:test/test.dart';

import 'package:torrent_tracker/torrent_tracker.dart';
import 'package:torrent_tracker/src/utils.dart';

/// 20-byte info hash used across the suite.
final Uint8List infoHash = Uint8List.fromList(List<int>.generate(20, (i) => i));

/// A second distinct info hash for multi-file scrape tests.
final Uint8List infoHash2 =
    Uint8List.fromList(List<int>.generate(20, (i) => 100 + i));

int u32(List<int> bytes, int offset) =>
    ByteData.view(Uint8List.fromList(bytes).buffer).getUint32(offset);

int u16(List<int> bytes, int offset) =>
    ByteData.view(Uint8List.fromList(bytes).buffer).getUint16(offset);

void main() {
  group('utils - big-endian integer packers', () {
    test('num2Uint16List packs big-endian', () {
      expect(num2Uint16List(1), equals([0, 1]));
      expect(num2Uint16List(0x1234), equals([0x12, 0x34]));
      expect(num2Uint16List(65535), equals([0xff, 0xff]));
    });

    test('num2Uint32List packs big-endian', () {
      expect(num2Uint32List(1), equals([0, 0, 0, 1]));
      expect(num2Uint32List(0x01020304), equals([1, 2, 3, 4]));
    });

    test('num2Uint64List packs big-endian', () {
      expect(num2Uint64List(1), equals([0, 0, 0, 0, 0, 0, 0, 1]));
      expect(
          num2Uint64List(0x0102030405060708), equals([1, 2, 3, 4, 5, 6, 7, 8]));
    });

    test('round-trips through ByteData', () {
      var packed = num2Uint32List(123456789);
      expect(u32(packed, 0), equals(123456789));
    });
  });

  group('utils - getPeerIPv4', () {
    test('decodes ip + big-endian port', () {
      var bytes = Uint8List.fromList([192, 168, 0, 1, 0x1a, 0xe1]); // :6881
      var view = ByteData.view(bytes.buffer);
      var uri = getPeerIPv4(view) as Uri;
      expect(uri.host, equals('192.168.0.1'));
      expect(uri.port, equals(6881));
    });
  });

  group('utils - transformToScrapeUrl', () {
    test('announce -> scrape (path)', () {
      expect(transformToScrapeUrl('http://t.org/announce'),
          equals('http://t.org/scrape'));
    });

    test('announce -> scrape keeps query', () {
      expect(transformToScrapeUrl('http://t.org/announce?x=1'),
          equals('http://t.org/scrape?x=1'));
    });

    test('trailing slash is trimmed', () {
      expect(transformToScrapeUrl('http://t.org/announce/'),
          equals('http://t.org/scrape'));
    });

    test('no announce segment -> null', () {
      expect(transformToScrapeUrl('http://t.org/foo'), isNull);
    });
  });

  group('UDP announce - request packet (BEP15)', () {
    late UDPTracker tracker;
    final connectionId = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final options = {
      'peerId': '-TT0001-123456789012',
      'downloaded': 100,
      'left': 200,
      'uploaded': 50,
      'numwant': 50,
      'port': 6881,
    };

    setUp(() async {
      tracker = UDPTracker(Uri.parse('udp://tracker.test:1337'), infoHash);
      // Close first so announce() only records the current event ('started')
      // and short-circuits before binding a socket / doing DNS (no real I/O).
      await tracker.close();
      tracker.announce('started', options);
    });

    test('packet has the correct length (98 bytes)', () {
      var msg = tracker.generateSecondTouchMessage(connectionId, options);
      // 8 conn + 4 action + 4 tid + 20 hash + 20 peerId + 8+8+8 + 4 event
      // + 4 ip + 4 key + 4 numwant + 2 port = 98
      expect(msg.length, equals(98));
    });

    test('packet fields are laid out per spec, big-endian', () {
      var msg = tracker.generateSecondTouchMessage(connectionId, options);
      expect(msg.sublist(0, 8), equals(connectionId));
      expect(u32(msg, 8), equals(1)); // ACTION_ANNOUNCE
      expect(msg.sublist(12, 16), equals(tracker.transcationId));
      expect(msg.sublist(16, 36), equals(infoHash));
      expect(utf8.decode(msg.sublist(36, 56)), equals(options['peerId']));
      expect(u32(msg.sublist(56, 64), 4), equals(100)); // downloaded (low word)
      expect(u32(msg.sublist(64, 72), 4), equals(200)); // left
      expect(u32(msg.sublist(72, 80), 4), equals(50)); // uploaded
      expect(u32(msg, 80), equals(2)); // event 'started' == 2
      expect(u32(msg, 84), equals(0)); // ip
      expect(u32(msg, 88), equals(0)); // key
      expect(u32(msg, 92), equals(50)); // num_want
      expect(u16(msg, 96), equals(6881)); // port
    });

    test('event code reflects the current event', () {
      tracker.announce('stopped', options);
      var msg = tracker.generateSecondTouchMessage(connectionId, options);
      expect(u32(msg, 80), equals(3)); // stopped == 3
      tracker.announce('completed', options);
      msg = tracker.generateSecondTouchMessage(connectionId, options);
      expect(u32(msg, 80), equals(1)); // completed == 1
    });
  });

  group('UDP announce - response parsing', () {
    late UDPTracker tracker;

    setUp(() {
      tracker = UDPTracker(Uri.parse('udp://tracker.test:1337'), infoHash);
    });

    tearDown(() async {
      await tracker.close();
    });

    /// Build an announce response: action(4) tid(4) interval(4)
    /// leechers(4) seeders(4) then compact peers.
    Uint8List buildResponse(
        int interval, int leechers, int seeders, List<List<int>> peers) {
      var b = <int>[];
      b.addAll(num2Uint32List(1)); // action announce
      b.addAll(num2Uint32List(0)); // tid (unchecked here)
      b.addAll(num2Uint32List(interval));
      b.addAll(num2Uint32List(leechers));
      b.addAll(num2Uint32List(seeders));
      for (var p in peers) {
        b.addAll(p);
      }
      return Uint8List.fromList(b);
    }

    List<int> peer(String ip, int port) {
      var parts = ip.split('.').map(int.parse).toList();
      return [...parts, ...num2Uint16List(port)];
    }

    final addr = [CompactAddress(InternetAddress('1.1.1.1'), 1337)];

    test('parses interval/seeders/leechers and peers', () {
      var data = buildResponse(1800, 7, 12, [
        peer('10.0.0.1', 6881),
        peer('10.0.0.2', 51413),
      ]);
      var event = tracker.processResponseData(data, 1, addr) as PeerEvent;
      expect(event.interval, equals(1800));
      expect(event.incomplete, equals(7)); // leechers
      expect(event.complete, equals(12)); // seeders
      expect(event.peers.length, equals(2));
      var ports = event.peers.map((p) => p.port).toSet();
      expect(ports, containsAll(<int>[6881, 51413]));
    });

    test('handles a response with zero peers', () {
      var data = buildResponse(900, 0, 0, []);
      var event = tracker.processResponseData(data, 1, addr) as PeerEvent;
      expect(event.peers, isEmpty);
      expect(event.interval, equals(900));
    });

    test('throws on a truncated response (<20 bytes)', () {
      var data = Uint8List.fromList(num2Uint32List(1) + num2Uint32List(0));
      expect(() => tracker.processResponseData(data, 1, addr),
          throwsA(isA<Exception>()));
    });
  });

  group('UDP scrape - request + response round-trip', () {
    late UDPScrape scrape;
    final connectionId = Uint8List.fromList([8, 7, 6, 5, 4, 3, 2, 1]);

    setUp(() {
      scrape = UDPScrape(Uri.parse('udp://tracker.test:1337'));
      scrape.addInfoHash(infoHash);
      scrape.addInfoHash(infoHash2);
    });

    tearDown(() async {
      await scrape.close();
    });

    test('request packet: conn id, action=2, tid, info hashes', () {
      var msg = scrape.generateSecondTouchMessage(connectionId, {});
      expect(msg.length, equals(8 + 4 + 4 + 20 * 2));
      expect(msg.sublist(0, 8), equals(connectionId));
      expect(u32(msg, 8), equals(2)); // ACTION_SCRAPE
      expect(msg.sublist(12, 16), equals(scrape.transcationId));
      expect(msg.sublist(16, 36), equals(infoHash));
      expect(msg.sublist(36, 56), equals(infoHash2));
    });

    test('empty info hash set throws when building request', () {
      var empty = UDPScrape(Uri.parse('udp://tracker.test:1337'));
      addTearDown(() => empty.close());
      expect(() => empty.generateSecondTouchMessage(connectionId, {}),
          throwsA(isA<Exception>()));
    });

    test('response: parses one 12-byte stats block per info hash', () {
      var b = <int>[];
      b.addAll(num2Uint32List(2)); // action scrape
      b.addAll(num2Uint32List(0)); // tid
      // file 0: seeders/downloaded/leechers
      b.addAll(num2Uint32List(10));
      b.addAll(num2Uint32List(100));
      b.addAll(num2Uint32List(3));
      // file 1
      b.addAll(num2Uint32List(20));
      b.addAll(num2Uint32List(200));
      b.addAll(num2Uint32List(5));
      var data = Uint8List.fromList(b);

      var event = scrape.processResponseData(data, 2, const []) as ScrapeEvent;
      expect(event.files.length, equals(2));
      var first =
          event.files[transformBufferToHexString(infoHash)] as ScrapeResult;
      expect(first.complete, equals(10));
      expect(first.downloaded, equals(100));
      expect(first.incomplete, equals(3));
      var second =
          event.files[transformBufferToHexString(infoHash2)] as ScrapeResult;
      expect(second.complete, equals(20));
      expect(second.downloaded, equals(200));
      expect(second.incomplete, equals(5));
    });

    test('response with wrong action throws', () {
      var data = Uint8List.fromList(num2Uint32List(3) + num2Uint32List(0));
      expect(() => scrape.processResponseData(data, 3, const []),
          throwsA(isA<Exception>()));
    });
  });

  group('HTTP announce - response parsing (bencode)', () {
    late HttpTracker tracker;

    setUp(() {
      tracker =
          HttpTracker(Uri.parse('http://tracker.test/announce'), infoHash);
    });

    tearDown(() async {
      await tracker.close();
    });

    Uint8List enc(Map<String, dynamic> m) =>
        Uint8List.fromList(bencode.encode(m)!);

    test('compact peers + interval + seeders/leechers', () {
      // two compact IPv4 peers
      var peers = <int>[
        10, 0, 0, 5, ...num2Uint16List(6881), //
        10, 0, 0, 6, ...num2Uint16List(6882),
      ];
      var data = enc({
        'interval': 1800,
        'min interval': 900,
        'complete': 42,
        'incomplete': 9,
        'downloaded': 1000,
        'peers': Uint8List.fromList(peers),
      });
      var event = tracker.processResponseData(data);
      expect(event.interval, equals(1800));
      expect(event.minInterval, equals(900));
      expect(event.complete, equals(42));
      expect(event.incomplete, equals(9));
      expect(event.downloaded, equals(1000));
      expect(event.peers.length, equals(2));
      expect(event.peers.map((p) => p.port).toSet(),
          containsAll(<int>[6881, 6882]));
    });

    test('dictionary-model peers list', () {
      var data = enc({
        'interval': 1200,
        'peers': [
          {'ip': '192.168.1.10', 'port': 6881, 'peer id': 'x'},
          {'ip': '192.168.1.11', 'port': 6882, 'peer id': 'y'},
        ],
      });
      var event = tracker.processResponseData(data);
      expect(event.interval, equals(1200));
      expect(event.peers.length, equals(2));
      expect(event.peers.map((p) => p.toString()),
          contains(startsWith('192.168.1.10')));
    });

    test('warning message is captured', () {
      var data = enc({
        'interval': 600,
        'warning message': 'slow down',
        'peers': Uint8List.fromList(<int>[]),
      });
      var event = tracker.processResponseData(data);
      expect(event.warning, equals('slow down'));
    });

    test('failure reason throws', () {
      var data = enc({'failure reason': 'torrent not registered'});
      expect(() => tracker.processResponseData(data),
          throwsA('torrent not registered'));
    });

    test('tracker id is recorded (decoded to String) for the next request', () {
      var data = enc({
        'interval': 1800,
        'tracker id': 'abc-123',
        'peers': Uint8List.fromList(<int>[]),
      });
      tracker.processResponseData(data);
      expect(tracker.currentTrackerId, equals('abc-123'));
    });
  });

  group('HTTP scrape - response parsing (bencode)', () {
    late HttpScrape scrape;

    setUp(() {
      scrape = HttpScrape(Uri.parse('http://tracker.test/scrape'));
    });

    tearDown(() async {
      await scrape.close();
    });

    test('parses per-file complete/incomplete/downloaded/name', () {
      // bencode 'files' is keyed by the raw 20-byte info hash.
      var rawKey = String.fromCharCodes(infoHash);
      var data = Uint8List.fromList(bencode.encode({
        'files': {
          rawKey: {
            'complete': 11,
            'incomplete': 4,
            'downloaded': 77,
            'name': 'ubuntu.iso',
          }
        }
      })!);
      var event = scrape.processResponseData(data) as ScrapeEvent;
      expect(event.files.length, equals(1));
      var hex = transformBufferToHexString(infoHash);
      var result = event.files[hex] as ScrapeResult;
      expect(result.complete, equals(11));
      expect(result.incomplete, equals(4));
      expect(result.downloaded, equals(77));
      expect(result.name, equals('ubuntu.iso'));
    });

    test('failure reason throws', () {
      var data = Uint8List.fromList(bencode.encode({'failure reason': 'nope'})!);
      expect(() => scrape.processResponseData(data),
          throwsA(isA<Exception>()));
    });
  });
}
