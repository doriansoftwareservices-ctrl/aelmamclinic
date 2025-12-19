// lib/screens/chat/chat_search_screen.dart
//
// شاشة البحث داخل محادثة (قريبة من واتساب):
// - شريط بحث أعلى مع رجوع / مسح / عداد النتائج وأزرار السابق/التالي
// - فلتر النوع: الكل / نصوص / صور  +  خيار "منّي فقط"
// - قائمة نتائج بفقاعات صغيرة (نص أو "📷 صورة") مع الوقت والبريد
// - تظليل نص المطابقة داخل النتيجة
// - بالضغط على نتيجة: نُعيد messageId إلى الشاشة السابقة لتنتقل إليها
//
// الملاحظات:
// - نعتمد مباشرة على ChatService (GraphQL) لتكون الشاشة مستقلة.
// - البحث يطابق body/text بـ ILIKE ويستثني الرسائل المحذوفة.
// - ترقيم النتائج محلي، مع أزرار تنقل بين النتائج (السهمين).
//
// الاعتمادات:
//   - chat_service
//   - core/neumorphism.dart
//   - core/theme.dart
//   - models/chat_models.dart
//   - utils/time.dart
//   - utils/text_direction.dart

import 'dart:async';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/utils/time.dart' as t;
import 'package:aelmamclinic/utils/text_direction.dart' as bidi;

class ChatSearchScreen extends StatefulWidget {
  final String conversationId;
  final String? title; // اختياري لعنوان الـ AppBar
  final String? initialQuery;

  const ChatSearchScreen({
    super.key,
    required this.conversationId,
    this.title,
    this.initialQuery,
  });

  @override
  State<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends State<ChatSearchScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  Timer? _debounce;

  // نتائج + مفاتيح للتمرير للعنصر المحدد
  List<ChatMessage> _results = [];
  List<GlobalKey> _resultKeys = [];
  bool _loading = false;
  String? _error;

  // فلاتر
  _KindFilter _kind = _KindFilter.all;
  bool _onlyMine = false;

  // مؤشر النتيجة المحددة (للتنقل بالسهمين)
  int _selected = -1;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery ?? '';
    if (_controller.text.trim().isNotEmpty) {
      _searchNow();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _searchNow);
    setState(() {}); // لتحديث زر المسح في شريط البحث فورًا
  }

  Future<void> _searchNow() async {
    final q = _controller.text.trim();
    setState(() {
      _loading = true;
      _error = null;
      _selected = -1;
    });

    try {
      final uid = NhostManager.client.auth.currentUser?.id ?? '';
      List<ChatMessage> list;
      if (q.isEmpty) {
        list = await ChatService.instance.fetchMessages(
          conversationId: widget.conversationId,
          limit: 200,
        );
      } else {
        list = await ChatService.instance.searchMessages(
          conversationId: widget.conversationId,
          query: q,
          limit: 200,
        );
      }

      // فلتر النوع
      list = list.where((m) {
        switch (_kind) {
          case _KindFilter.texts:
            return m.kind == ChatMessageKind.text;
          case _KindFilter.images:
            return m.kind == ChatMessageKind.image;
          case _KindFilter.all:
            return true;
        }
      }).toList();

      // فلتر "منّي فقط"
      if (_onlyMine && uid.isNotEmpty) {
        list = list.where((m) => m.senderUid == uid).toList();
      }

      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() {
        _results = list;
        _resultKeys = List.generate(_results.length, (_) => GlobalKey());
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'تعذّر البحث: $e';
        _results = [];
        _resultKeys = [];
        _loading = false;
      });
    }
  }

  void _clearQuery() {
    _controller.clear();
    _onQueryChanged('');
  }

  void _selectIndex(int idx) {
    if (_results.isEmpty) return;
    idx = idx.clamp(0, _results.length - 1);
    setState(() => _selected = idx);
    // تمرير للعنصر
    final key = _resultKeys[idx];
    final ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        alignment: .3,
      );
    }
  }

  void _next() {
    if (_results.isEmpty) return;
    if (_selected == -1) {
      _selectIndex(0);
    } else {
      _selectIndex((_selected + 1).clamp(0, _results.length - 1));
    }
  }

  void _prev() {
    if (_results.isEmpty) return;
    if (_selected == -1) {
      _selectIndex(0);
    } else {
      _selectIndex((_selected - 1).clamp(0, _results.length - 1));
    }
  }

  // إرسال النتيجة المختارة إلى الشاشة السابقة (لتتم عملية التمرير هناك)
  void _jumpToSelectedInRoom(int i) {
    if (i < 0 || i >= _results.length) return;
    final id = _results[i].id;
    Navigator.of(context).pop<String?>(id);
  }

  String _resolveTextContent(ChatMessage message) {
    final body = message.body;
    if (body != null) {
      final trimmed = body.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return message.text;
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = _controller.text.trim().isNotEmpty;
    final count = _results.length;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          elevation: 0,
          titleSpacing: 0,
          title: _SearchBar(
            controller: _controller,
            hint: 'ابحث داخل المحادثة',
            onChanged: _onQueryChanged,
            onClear: _clearQuery,
            onSubmit: (_) => _searchNow(),
          ),
          actions: [
            // عدّاد + السابق/التالي
            if (!_loading && hasQuery)
              Center(
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  child: Text(
                    count == 0
                        ? '0/0'
                        : (_selected == -1
                            ? '— / $count'
                            : '${_selected + 1} / $count'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            if (!_loading && hasQuery)
              IconButton(
                tooltip: 'السابق',
                onPressed: count > 0 ? _prev : null,
                icon: const Icon(Icons.keyboard_arrow_right_rounded),
              ),
            if (!_loading && hasQuery)
              IconButton(
                tooltip: 'التالي',
                onPressed: count > 0 ? _next : null,
                icon: const Icon(Icons.keyboard_arrow_left_rounded),
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            _FiltersRow(
              kind: _kind,
              onlyMine: _onlyMine,
              onKindChanged: (k) {
                setState(() => _kind = k);
                _onQueryChanged(_controller.text);
              },
              onOnlyMineChanged: (v) {
                setState(() => _onlyMine = v);
                _onQueryChanged(_controller.text);
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const _CenterMsg(
                      icon: Icons.search_rounded, text: 'جارٍ البحث...')
                  : _error != null
                      ? _CenterMsg(
                          icon: Icons.error_outline_rounded, text: _error!)
                      : _buildResults(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_controller.text.trim().isEmpty) {
      return const _CenterMsg(
        icon: Icons.search_rounded,
        text: 'ابدأ الكتابة للبحث داخل هذه المحادثة',
      );
    }
    if (_results.isEmpty) {
      return const _CenterMsg(
        icon: Icons.inbox_outlined,
        text: 'لا توجد نتائج مطابقة',
      );
    }

    final query = _controller.text.trim();

    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final m = _results[i];
        final isSelected = i == _selected;
        final time = t.formatChatListTimestamp(m.createdAt);
        final isImage = m.kind == ChatMessageKind.image;
        final text = isImage
            ? (m.body?.trim().isNotEmpty == true ? m.body!.trim() : '📷 صورة')
            : _resolveTextContent(m);

        final borderColor =
            isSelected ? kPrimaryColor : Theme.of(context).dividerColor;

        return Padding(
          key: _resultKeys[i],
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor),
              ),
              child: ListTile(
                onTap: () => _jumpToSelectedInRoom(i),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: kPrimaryColor.withValues(alpha: .08),
                  child: Icon(
                    isImage ? Icons.image_rounded : Icons.text_snippet_rounded,
                    color: kPrimaryColor,
                  ),
                ),
                title: _Highlighted(
                  text: text.isEmpty ? '—' : text,
                  query: query,
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      if ((m.senderEmail ?? '').isNotEmpty)
                        Flexible(
                          child: Text(
                            m.senderEmail!,
                            textDirection: ui.TextDirection.ltr,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if ((m.senderEmail ?? '').isNotEmpty)
                        const SizedBox(width: 6),
                      Text(
                        time,
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: .6),
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                trailing: IconButton(
                  tooltip: 'انتقال',
                  onPressed: () => _jumpToSelectedInRoom(i),
                  icon: const Icon(Icons.open_in_new_rounded),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/*────────────────────────── Widgets فرعية ─────────────────────────*/

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmit;
  final VoidCallback? onClear;

  const _SearchBar({
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmit,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Container(
        margin: const EdgeInsetsDirectional.only(end: 8, top: 6, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.search,
                onChanged: onChanged,
                onSubmitted: onSubmit,
                decoration: InputDecoration(
                  hintText: hint,
                  border: InputBorder.none,
                ),
              ),
            ),
            if (controller.text.isNotEmpty)
              IconButton(
                tooltip: 'مسح',
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

enum _KindFilter { all, texts, images }

class _FiltersRow extends StatelessWidget {
  final _KindFilter kind;
  final bool onlyMine;
  final ValueChanged<_KindFilter> onKindChanged;
  final ValueChanged<bool> onOnlyMineChanged;

  const _FiltersRow({
    required this.kind,
    required this.onlyMine,
    required this.onKindChanged,
    required this.onOnlyMineChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Choice(
              selected: kind == _KindFilter.all,
              label: 'الكل',
              icon: Icons.all_inbox_rounded,
              onTap: () => onKindChanged(_KindFilter.all),
            ),
            _Choice(
              selected: kind == _KindFilter.texts,
              label: 'نصوص',
              icon: Icons.text_snippet_rounded,
              onTap: () => onKindChanged(_KindFilter.texts),
            ),
            _Choice(
              selected: kind == _KindFilter.images,
              label: 'صور',
              icon: Icons.image_rounded,
              onTap: () => onKindChanged(_KindFilter.images),
            ),
            const SizedBox(width: 8),
            FilterChip(
              selected: onlyMine,
              onSelected: onOnlyMineChanged,
              label: const Text('منّي فقط'),
              avatar: const Icon(Icons.person_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _Choice({
    required this.selected,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = selected ? kPrimaryColor : Theme.of(context).colorScheme.outline;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c),
          color: selected ? kPrimaryColor.withValues(alpha: .08) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: c),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: c,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Highlighted extends StatelessWidget {
  final String text;
  final String query;

  const _Highlighted({required this.text, required this.query});

  @override
  Widget build(BuildContext context) {
    // اتجاه نص ذكي (إيميل/لاتيني LTR وإلا RTL)
    final dir = bidi.ltrIfEmailOrLatinElseRtl(text);
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontWeight: FontWeight.w800,
    );
    if (query.trim().isEmpty) {
      return Text(
        text,
        textDirection: dir,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final spans = _buildSpans(text, query, style);
    return RichText(
      textDirection: dir,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: spans),
    );
  }

  List<TextSpan> _buildSpans(String source, String needle, TextStyle base) {
    final s = source;
    final q = needle;
    final lower = s.toLowerCase();
    final n = q.toLowerCase();

    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final idx = lower.indexOf(n, start);
      if (idx < 0) {
        spans.add(TextSpan(text: s.substring(start), style: base));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: s.substring(start, idx), style: base));
      }
      spans.add(TextSpan(
        text: s.substring(idx, idx + n.length),
        style: base.copyWith(
          backgroundColor: kPrimaryColor.withValues(alpha: .25),
          color: base.color,
        ),
      ));
      start = idx + n.length;
      if (start >= s.length) break;
    }
    return spans;
  }
}

class _CenterMsg extends StatelessWidget {
  final IconData icon;
  final String text;
  const _CenterMsg({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Theme.of(context).hintColor),
            const SizedBox(height: 10),
            Text(
              text,
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: .7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
