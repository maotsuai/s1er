import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/constants.dart';
import '../models/open_scroll_target.dart';
import '../models/post.dart';
import '../models/poll.dart';
import '../models/thread_open_intent.dart';
import '../services/api_service.dart';
import '../services/discuz_parser.dart';
import '../services/http_client.dart';
import '../services/poll_vote_cache.dart';
import '../services/rate_log_service.dart';
import '../services/talker.dart';
import '../utils/thread_navigation.dart';
import 'api_service_provider.dart';
import 'pinned_threads_provider.dart';
import 'reading_history_provider.dart';
import 'settings_provider.dart';
import 'thread_open_intent_provider.dart';
import 'thread_rate_logs_provider.dart';

class PostListState {
  PostListState({
    this.posts = const [],
    this.currentPage = 1,
    this.totalPages = 1,
    this.threadSubject,
    this.threadFid,
    this.threadSpecial = 0,
    this.perPage = S1Constants.postsPerPageFallback,
    this.totalReplies = 0,
    this.poll,
    this.filterAuthorId,
    this.filterAuthorName,
    this.allowReply = true,
    this.openScrollTarget,
    this.locateError,
  });

  final List<Post> posts;
  final int currentPage;
  final int totalPages;
  final String? threadSubject;
  final String? threadFid;
  final int threadSpecial;
  final int perPage;
  final int totalReplies;
  final ThreadPoll? poll;
  final String? filterAuthorId;
  final String? filterAuthorName;
  final bool allowReply;

  /// 首屏一次性滚动落点；Screen 消费后应通过 [clearOpenScrollTarget] 清除。
  final OpenScrollTarget? openScrollTarget;

  /// pid 定位失败时的用户可读说明（加载仍可能落到某一页）。
  final String? locateError;

  bool get isFiltering => filterAuthorId != null;

  PostListState copyWith({
    List<Post>? posts,
    int? currentPage,
    int? totalPages,
    String? threadSubject,
    String? threadFid,
    int? threadSpecial,
    int? perPage,
    int? totalReplies,
    ThreadPoll? poll,
    String? filterAuthorId,
    String? filterAuthorName,
    bool clearFilter = false,
    bool? allowReply,
    OpenScrollTarget? openScrollTarget,
    bool clearOpenScrollTarget = false,
    String? locateError,
    bool clearLocateError = false,
  }) {
    return PostListState(
      posts: posts ?? this.posts,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      threadSubject: threadSubject ?? this.threadSubject,
      threadFid: threadFid ?? this.threadFid,
      threadSpecial: threadSpecial ?? this.threadSpecial,
      perPage: perPage ?? this.perPage,
      totalReplies: totalReplies ?? this.totalReplies,
      poll: poll ?? this.poll,
      filterAuthorId:
          clearFilter ? null : (filterAuthorId ?? this.filterAuthorId),
      filterAuthorName:
          clearFilter ? null : (filterAuthorName ?? this.filterAuthorName),
      allowReply: allowReply ?? this.allowReply,
      openScrollTarget: clearOpenScrollTarget
          ? null
          : (openScrollTarget ?? this.openScrollTarget),
      locateError: clearLocateError ? null : (locateError ?? this.locateError),
    );
  }
}

final rateLogServiceProvider = Provider<RateLogService>((ref) {
  return RateLogService(ref.watch(httpClientProvider));
});

final pollVoteCacheProvider =
    Provider.autoDispose.family<PollVoteCache, String>((ref, uid) {
  ref.watch(pollVotesBootstrapProvider);
  return PollVoteCache(ref.watch(localDataProvider), uid);
});

class PostNotifier extends AsyncNotifier<PostListState> {
  PostNotifier(this.tid);

  final String tid;
  String? _filterAuthorId;
  String? _filterAuthorName;
  final _pages = <int, PostListState>{};
  final _inFlightPages = <int, Future<PostListState>>{};
  int _cacheGeneration = 0;
  int _navigationVersion = 0;
  int? _readingPage;

  ApiService get _apiService => ref.read(apiServiceProvider);

  @override
  Future<PostListState> build() async {
    ref.onDispose(() {
      _cacheGeneration++;
      _navigationVersion++;
      _pages.clear();
      _inFlightPages.clear();
    });
    // 与读帖同生命周期挂住评分 provider；select 常量避免 merge 触发本 Notifier 重建。
    ref.watch(threadRateLogsProvider(tid).select((_) => null));

    final intent = ref.read(threadOpenIntentProvider(tid));
    final mode = intent?.mode ?? ThreadOpenMode.resume;

    if (mode == ThreadOpenMode.post) {
      final pid = intent?.pid;
      if (pid != null && pid.isNotEmpty) {
        return _openByPid(pid);
      }
    }

    if (mode == ThreadOpenMode.page) {
      final page = resolveThreadInitialPage(intent: intent, record: null);
      final loaded = await _loadPage(page);
      return loaded.copyWith(openScrollTarget: const ScrollToPageTop());
    }

    // resume
    final record = ref.read(readingRecordProvider(tid));
    var page = resolveThreadInitialPage(intent: intent, record: record);
    var loaded = await _loadPage(page);

    // B3：列表未提供 live 回复数、且 API 发现更多未读时再校正一页。
    if (record != null &&
        record.isFinished &&
        record.hasNewReplies(loaded.totalReplies)) {
      final targetPage = record.resolveOpenPage(
        loaded.totalReplies,
        perPage: loaded.perPage,
      );
      final listLive = intent?.liveTotalReplies;
      final needsCorrection = loaded.currentPage != targetPage &&
          (listLive == null || listLive < loaded.totalReplies);
      if (needsCorrection) {
        _readingPage = targetPage;
        loaded = await _loadPage(targetPage);
      }
    }

    final scrollTarget = resolveResumeScrollTarget(
      record: record,
      loadedPage: loaded.currentPage,
      liveTotalReplies: loaded.totalReplies,
      perPage: loaded.perPage,
    );
    return loaded.copyWith(openScrollTarget: scrollTarget);
  }

  Future<PostListState> _openByPid(String pid) async {
    final version = _navigationVersion;
    try {
      final page = await _apiService.locatePostPage(tid, pid);
      if (!ref.mounted || version != _navigationVersion) {
        throw StateError('Post navigation superseded');
      }
      _readingPage = page;
      final cached = _pages[page];
      // 目标可能是缓存之后新增的楼层；不能把旧快照中的缺失当成远端缺失。
      final canLocateFromCache =
          cached != null && cached.posts.any((p) => p.pid == pid);
      final loaded = canLocateFromCache ? cached : await _loadPage(page);
      if (canLocateFromCache) {
        // 延后一轮，先让定位结果发布到 state。
        unawaited(Future<void>(() => _revalidatePage(page, version)));
      }
      final found = loaded.posts.any((p) => p.pid == pid);
      if (!found) {
        return loaded.copyWith(
          openScrollTarget: const ScrollToPageTop(),
          locateError: '未找到目标楼层',
        );
      }
      return loaded.copyWith(
        openScrollTarget: ScrollToPid(pid),
        clearLocateError: true,
      );
    } catch (e, st) {
      if (!ref.mounted || version != _navigationVersion) rethrow;
      talker.handle(e, st, 'locatePid failed tid=$tid pid=$pid');
      _readingPage = 1;
      final loaded = await _loadPage(1);
      return loaded.copyWith(
        openScrollTarget: const ScrollToPageTop(),
        locateError: '定位楼层失败',
      );
    }
  }

  ThreadPoll? _pollWithUserVotes(
    Map<String, dynamic> variables,
    ThreadPoll? poll,
  ) {
    if (poll == null || !ref.mounted) return poll;
    final uid = variables['member_uid']?.toString() ?? '';
    if (uid.isEmpty || uid == '0') return poll;
    final votes = ref.read(pollVoteCacheProvider(uid)).getVotes(tid);
    return votes.isEmpty ? poll : poll.withUserVotes(votes);
  }

  Future<PostListState> _loadPage(int page) {
    _readingPage ??= page;
    return _inFlightPages.putIfAbsent(page, () {
      final generation = _cacheGeneration;
      final authorId = _filterAuthorId;
      final authorName = _filterAuthorName;
      late final Future<PostListState> future;
      future = _fetchPage(page, authorId, authorName).then((loaded) {
        if (ref.mounted &&
            generation == _cacheGeneration &&
            identical(_inFlightPages[page], future)) {
          _pages[page] = loaded;
          _trimPageCache();
          if (_pages.containsKey(page)) _onPageLoaded(loaded);
        }
        return loaded;
      }).whenComplete(() {
        if (identical(_inFlightPages[page], future)) {
          _inFlightPages.remove(page);
        }
      });
      return future;
    });
  }

  void _trimPageCache() {
    if (_pages.length <= S1Constants.postSessionCacheMaxPages) return;
    final current = _readingPage ?? _pages.keys.last;
    _pages.removeWhere(
      (page, _) =>
          (page - current).abs() > S1Constants.postSessionCachePageRadius,
    );
    final retained = _pages.keys.toSet();
    _inFlightPages.removeWhere((page, _) => !retained.contains(page));
    ref.read(threadRateLogsProvider(tid).notifier).retainPages(retained);
  }

  void _clearPageCache() {
    _cacheGeneration++;
    _navigationVersion++;
    _pages.clear();
    _inFlightPages.clear();
    ref.read(threadRateLogsProvider(tid).notifier).clear();
  }

  Future<PostListState> _fetchPage(
    int page,
    String? authorId,
    String? authorName,
  ) async {
    final result = await _apiService.getThreadDetail(
      tid,
      page: page,
      authorId: authorId,
    );
    final posts = await ApiService.parsePostListAsync(result);
    return _buildStateFromResult(result, page, posts: posts).copyWith(
      filterAuthorId: authorId,
      filterAuthorName: authorName,
      clearFilter: authorId == null,
    );
  }

  void _onPageLoaded(PostListState loaded) {
    final page = loaded.currentPage;
    _syncSeenRepliesAfterLoad(loaded);

    // 评分明细只在 HTML viewthread 的 #ratelog_*；Mobile JSON 的 postlist
    // 不含楼层 rate（thread.rate 仅主题级标记）。会话缓存避免同页重复拉取。
    unawaited(
      ref
          .read(threadRateLogsProvider(tid).notifier)
          .ensurePageRateLogs(page)
          .catchError((Object e, StackTrace st) {
        talker.handle(e, st, 'ensurePageRateLogs failed tid=$tid page=$page');
      }),
    );
  }

  /// 打开置顶帖时对齐 live / lastSeen（不碰阅读记录）。
  void _syncSeenRepliesAfterLoad(PostListState loaded) {
    if (!ref.mounted) return;
    final notifier = ref.read(pinnedThreadsProvider.notifier);
    if (!notifier.isPinned(tid)) return;
    notifier.markOpened(tid, loaded.totalReplies);
  }

  PostListState _buildStateFromResult(
    Map<String, dynamic> result,
    int page, {
    List<Post>? posts,
  }) {
    final parsedPosts = posts ?? DiscuzParser.parsePostList(result);
    final variables = result['Variables'] as Map<String, dynamic>? ?? {};
    final thread = variables['thread'] as Map<String, dynamic>? ?? {};
    final perPage = int.tryParse(variables['ppp']?.toString() ?? '') ??
        S1Constants.postsPerPageFallback;
    final totalReplies = int.tryParse(thread['replies']?.toString() ?? '') ?? 0;
    final totalPosts = totalReplies + 1;
    final totalPages = (totalPosts / perPage).ceil().clamp(1, 9999);
    final allowReply = thread['allowreply']?.toString() != '0';
    final threadSpecial =
        int.tryParse(thread['special']?.toString() ?? '') ?? 0;

    return PostListState(
      posts: parsedPosts,
      currentPage: page,
      totalPages: totalPages,
      threadSubject: thread['subject']?.toString(),
      threadFid: thread['fid']?.toString(),
      threadSpecial: threadSpecial,
      perPage: perPage,
      totalReplies: totalReplies,
      poll: page == 1
          ? _pollWithUserVotes(variables, DiscuzParser.parsePoll(result))
          : null,
      filterAuthorId: _filterAuthorId,
      filterAuthorName: _filterAuthorName,
      allowReply: allowReply,
    );
  }

  Future<void> locatePid(String pid) async {
    final version = ++_navigationVersion;
    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<PostListState>().copyWithPrevious(state);
    final loaded = await AsyncValue.guard(() => _openByPid(pid));
    if (ref.mounted && version == _navigationVersion) state = loaded;
  }

  /// 引用跳转返回：恢复到指定页并滚到绝对楼层（同页不重载）。
  ///
  /// 成功返回 `true`；跨页加载失败并回滚后返回 `false`（此时 `hasError` 已清除）。
  Future<bool> restoreToFloor({
    required int page,
    required int absoluteFloor,
  }) async {
    final previous = state.asData?.value;
    if (previous != null && previous.currentPage == page) {
      _navigationVersion++;
      _readingPage = page;
      state = AsyncValue.data(
        previous.copyWith(
          openScrollTarget: ScrollToFloor(absoluteFloor),
          clearLocateError: true,
        ),
      );
      return true;
    }
    return _showPage(page, ScrollToFloor(absoluteFloor));
  }

  Future<void> goToPage(int page) async {
    await _showPage(page, const ScrollToPageTop());
  }

  /// 命中时同步展示缓存，远程校验不阻塞翻页或重置滚动落点。
  Future<bool> _showPage(int page, OpenScrollTarget target) async {
    final version = ++_navigationVersion;
    final previous = state.asData?.value;
    _readingPage = page;
    final cached = _pages[page];
    if (cached != null) {
      state = AsyncValue.data(cached.copyWith(openScrollTarget: target));
      unawaited(_revalidatePage(page, version));
      return true;
    }
    final loaded = await AsyncValue.guard(() => _loadPage(page));
    if (!ref.mounted || version != _navigationVersion) return false;
    if (loaded.hasError) {
      _readingPage = previous?.currentPage;
      state = previous == null ? loaded : AsyncValue.data(previous);
      return false;
    }
    state =
        AsyncValue.data(loaded.requireValue.copyWith(openScrollTarget: target));
    return true;
  }

  Future<void> _revalidatePage(int page, int version) async {
    if (!ref.mounted || version != _navigationVersion) return;
    try {
      final loaded = await _loadPage(page);
      if (!ref.mounted || version != _navigationVersion) return;
      final current = state.asData?.value;
      if (current == null || current.currentPage != page) return;
      state = AsyncValue.data(
        loaded.copyWith(
          openScrollTarget: current.openScrollTarget,
          locateError: current.locateError,
        ),
      );
    } catch (e, st) {
      // 校验失败时继续展示已读缓存，不用错误页打断阅读。
      talker.handle(e, st, 'revalidatePage failed tid=$tid page=$page');
    }
  }

  void clearOpenScrollTarget() {
    final current = state.asData?.value;
    if (current == null || current.openScrollTarget == null) return;
    state = AsyncValue.data(current.copyWith(clearOpenScrollTarget: true));
  }

  Future<void> filterByAuthor(String authorId, String authorName) async {
    _clearPageCache();
    _readingPage = 1;
    _filterAuthorId = authorId;
    _filterAuthorName = authorName;
    state = const AsyncValue.loading();
    final version = _navigationVersion;
    final loaded = await AsyncValue.guard(() => _loadPage(1));
    if (ref.mounted && version == _navigationVersion) state = loaded;
  }

  Future<void> clearFilter() async {
    _clearPageCache();
    _readingPage = 1;
    _filterAuthorId = null;
    _filterAuthorName = null;
    state = const AsyncValue.loading();
    final version = _navigationVersion;
    final loaded = await AsyncValue.guard(() => _loadPage(1));
    if (ref.mounted && version == _navigationVersion) state = loaded;
  }

  Future<void> refresh() async {
    final current = state.asData?.value.currentPage ?? 1;
    final version = ++_navigationVersion;
    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<PostListState>().copyWithPrevious(state);
    final loaded = await AsyncValue.guard(() => _loadPage(current));
    if (ref.mounted && version == _navigationVersion) state = loaded;
  }

  /// 异步抓取整帖所有页面的帖子列表（供跨页引用搜索使用，不更改当前 UI 显示状态）
  Future<List<Post>> fetchAllPagesPosts() async {
    final currentState = state.value;
    if (currentState == null) return const [];
    final totalPages = currentState.totalPages;
    final allPosts = <Post>[...currentState.posts];

    // 最多搜索前 10 页避免极长主题风控
    final maxSearchPages = totalPages > 10 ? 10 : totalPages;

    for (var p = 1; p <= maxSearchPages; p++) {
      if (p == currentState.currentPage) continue;
      try {
        if (!ref.mounted) break;
        final pageState = _pages[p] ?? await _loadPage(p);
        allPosts.addAll(pageState.posts);
      } catch (e, st) {
        talker.warning('Failed to load page $p for quote search', e, st);
      }
    }
    return allPosts;
  }
}

final postProvider = AsyncNotifierProvider.autoDispose
    .family<PostNotifier, PostListState, String>(
  PostNotifier.new,
  dependencies: [threadOpenIntentProvider],
);
