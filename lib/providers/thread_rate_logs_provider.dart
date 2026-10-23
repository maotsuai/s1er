import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/rate_log.dart';
import 'post_provider.dart';

typedef RateLogKey = (String tid, String pid);

class ThreadRateLogsNotifier extends Notifier<Map<String, PostRateLog>> {
  ThreadRateLogsNotifier(this.tid);

  final String tid;
  final Map<int, Future<void>> _inFlightPages = {};
  final Map<int, Map<String, PostRateLog>> _pages = {};
  int _cacheGeneration = 0;

  @override
  Map<String, PostRateLog> build() {
    ref.onDispose(() {
      _cacheGeneration++;
      _pages.clear();
      _inFlightPages.clear();
    });
    return const {};
  }

  void clear() {
    _cacheGeneration++;
    _inFlightPages.clear();
    _pages.clear();
    state = const {};
  }

  /// 与正文分页一起淘汰，已发出的旧请求也不能重新填回被清理的页。
  void retainPages(Set<int> pages) {
    _pages.removeWhere((page, _) => !pages.contains(page));
    _inFlightPages.removeWhere((page, _) => !pages.contains(page));
    state = {for (final logs in _pages.values) ...logs};
  }

  void mergePage(Map<String, PostRateLog> rateLogs) {
    if (rateLogs.isEmpty) return;
    state = {...state, ...rateLogs};
  }

  void replacePage(Map<String, PostRateLog> rateLogs) {
    state = rateLogs;
  }

  void setForPid(String pid, PostRateLog log) {
    state = {...state, pid: log};
  }

  Future<void> ensurePageRateLogs(int page, {bool force = false}) {
    if (!force) {
      final cached = _pages[page];
      if (cached != null) {
        mergePage(cached);
        return Future.value();
      }
    }

    final inFlight = _inFlightPages[page];
    if (inFlight != null) return inFlight;

    final service = ref.read(rateLogServiceProvider);
    late final Future<void> future;
    future = service.fetchRateLogs(tid, page: page).then((rateLogs) {
      if (!ref.mounted || !identical(_inFlightPages[page], future)) return;
      final previous = _pages[page];
      _pages[page] = rateLogs;
      state = {...state}
        ..removeWhere((pid, _) => previous?.containsKey(pid) ?? false);
      mergePage(rateLogs);
    }).whenComplete(() {
      if (identical(_inFlightPages[page], future)) _inFlightPages.remove(page);
    });
    _inFlightPages[page] = future;
    return future;
  }

  Future<void> loadFullRateLog(String pid) async {
    final generation = _cacheGeneration;
    int? page;
    Map<String, PostRateLog>? cached;
    for (final entry in _pages.entries) {
      if (entry.value.containsKey(pid)) {
        page = entry.key;
        cached = entry.value;
        break;
      }
    }
    final service = ref.read(rateLogServiceProvider);
    final full = await service.fetchFullRateLog(tid, pid);
    if (!ref.mounted || generation != _cacheGeneration || full == null) return;
    if (page != null && !identical(_pages[page], cached)) return;
    setForPid(pid, full);
    if (page != null && cached != null) {
      _pages[page] = {...cached, pid: full};
    }
  }
}

final threadRateLogsProvider = NotifierProvider.autoDispose
    .family<ThreadRateLogsNotifier, Map<String, PostRateLog>, String>(
  ThreadRateLogsNotifier.new,
);

/// 按 (tid, pid) 订阅单条评分日志。
final rateLogProvider = Provider.autoDispose.family<PostRateLog?, RateLogKey>(
  (ref, key) {
    final (tid, pid) = key;
    return ref.watch(threadRateLogsProvider(tid).select((logs) => logs[pid]));
  },
);
