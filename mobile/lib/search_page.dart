import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

/// Text-in-photos search (OCR index on the server), shown inside the Library tab
/// while a query is typed. Debounces the query and highlights matches in the viewer.
class LibrarySearch extends StatefulWidget {
  final PhotobankApi api;
  final String query;
  const LibrarySearch({super.key, required this.api, required this.query});
  @override
  State<LibrarySearch> createState() => _LibrarySearchState();
}

class _LibrarySearchState extends State<LibrarySearch> {
  Timer? _debounce;
  String _q = '';
  List<TextSearchResult>? _results;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _schedule(widget.query);
  }

  @override
  void didUpdateWidget(covariant LibrarySearch old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _schedule(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q.trim()));
  }

  Future<void> _search(String q) async {
    if (!mounted) return;
    setState(() {
      _q = q;
      _error = null;
    });
    if (q.length < 2) {
      setState(() => _results = null);
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await widget.api.searchText(q);
      if (mounted && _q == q) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _error != null
              ? Center(child: Text('Search failed: $_error'))
              : results == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Finds words inside your photos - signs, receipts, screenshots, menus.\n'
                          'Type at least 2 characters.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    )
                  : results.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No photos with "$_q" in them. Text is read in the background after '
                              'upload, so very recent photos may not be searchable yet.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(4),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                          itemCount: results.length,
                          itemBuilder: (context, i) {
                            final r = results[i];
                            return GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => MatchViewer(api: widget.api, result: r, query: _q),
                                ),
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.network(widget.api.thumbUrl(r.asset.id),
                                      headers: widget.api.authHeaders, cacheWidth: 360, fit: BoxFit.cover),
                                  Positioned(
                                    right: 4, top: 4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                      decoration: BoxDecoration(
                                          color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                                      child: Text('${r.matches.length}×',
                                          style: const TextStyle(fontSize: 11)),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

/// Full-screen preview with the matched words outlined at their positions.
class MatchViewer extends StatelessWidget {
  final PhotobankApi api;
  final TextSearchResult result;
  final String query;
  const MatchViewer({super.key, required this.api, required this.result, required this.query});

  @override
  Widget build(BuildContext context) {
    final a = result.asset;
    final aspect = (a.width != null && a.height != null && a.height! > 0)
        ? a.width! / a.height!
        : 4 / 3;
    final words = result.matches.map((m) => m.word).toSet().take(6).join(', ');
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x00000000)],
            ),
          ),
        ),
        title: Text('${result.matches.length} match${result.matches.length == 1 ? '' : 'es'}: $words',
            style: const TextStyle(fontSize: 14, color: Colors.white)),
      ),
      body: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // fit the image inside the viewport keeping its aspect ratio, so the
            // normalized boxes map 1:1 onto the drawn image
            var w = constraints.maxWidth;
            var h = w / aspect;
            if (h > constraints.maxHeight) {
              h = constraints.maxHeight;
              w = h * aspect;
            }
            return SizedBox(
              width: w,
              height: h,
              child: InteractiveViewer(
                maxScale: 5,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.network(api.previewUrl(a.id),
                          headers: api.authHeaders, fit: BoxFit.fill),
                    ),
                    for (final m in result.matches)
                      Positioned(
                        left: m.x * w,
                        top: m.y * h,
                        width: m.w * w,
                        height: m.h * h,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                            borderRadius: BorderRadius.circular(3),
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
