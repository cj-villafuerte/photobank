import 'package:flutter/material.dart';

import 'api.dart';
import 'format.dart';

const _mark = Color(0xFF3E90E8); // validated against the dark surface (dataviz checks)

class StatsPage extends StatefulWidget {
  final PhotobankApi api;
  const StatsPage({super.key, required this.api});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  int _days = 90;
  Stats? _stats;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _stats = null;
      _error = null;
    });
    try {
      final s = await widget.api.stats(_days);
      if (mounted) setState(() => _stats = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<DailyStat> _filled(List<DailyStat> daily) {
    final byDate = {for (final d in daily) d.date: d};
    final now = DateTime.now();
    return List.generate(_days, (i) {
      final d = now.subtract(Duration(days: _days - 1 - i));
      final key = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      return byDate[key] ?? DailyStat(key, 0, 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 30, label: Text('30d')),
                ButtonSegment(value: 90, label: Text('90d')),
                ButtonSegment(value: 365, label: Text('1y')),
              ],
              selected: {_days},
              onSelectionChanged: (sel) {
                setState(() => _days = sel.first);
                _load();
              },
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load: $_error'))
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        children: [
                          _tile('Items', '${s.totalCount}'),
                          const SizedBox(width: 8),
                          _tile('Photos', '${s.imageCount}'),
                          const SizedBox(width: 8),
                          _tile('Videos', '${s.videoCount}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(children: [_tile('Library size', fmtBytes(s.totalBytes))]),
                      const SizedBox(height: 20),
                      _BarChart(
                        title: 'Media per day (last $_days days)',
                        data: _filled(s.daily),
                        value: (d) => d.count.toDouble(),
                        format: (v) => v.round().toString(),
                      ),
                      const SizedBox(height: 16),
                      _BarChart(
                        title: 'Storage added per day',
                        data: _filled(s.daily),
                        value: (d) => d.bytes.toDouble(),
                        format: (v) => fmtBytes(v.round()),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _tile(String label, String value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: [
                Text(value, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(label, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
}

class _BarChart extends StatefulWidget {
  final String title;
  final List<DailyStat> data;
  final double Function(DailyStat) value;
  final String Function(double) format;
  const _BarChart({required this.title, required this.data, required this.value, required this.format});
  @override
  State<_BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<_BarChart> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final values = widget.data.map(widget.value).toList();
    final max = values.fold<double>(1, (m, v) => v > m ? v : m);
    final sel = _selected;
    final dim = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            SizedBox(
              height: 20,
              child: sel == null
                  ? Text('Tap a bar for details', style: TextStyle(color: dim, fontSize: 12))
                  : Text(
                      '${_pretty(widget.data[sel].date)}: ${widget.format(values[sel])}',
                      style: const TextStyle(fontSize: 12),
                    ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 140,
              child: LayoutBuilder(
                builder: (context, c) => GestureDetector(
                  onTapDown: (d) => setState(() =>
                      _selected = (d.localPosition.dx / c.maxWidth * values.length)
                          .floor()
                          .clamp(0, values.length - 1)),
                  child: CustomPaint(
                    size: Size(c.maxWidth, 140),
                    painter: _BarPainter(values, max, sel, Theme.of(context).colorScheme.outline),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_pretty(widget.data.first.date), style: TextStyle(color: dim, fontSize: 11)),
                Text('max ${widget.format(max)}', style: TextStyle(color: dim, fontSize: 11)),
                Text(_pretty(widget.data.last.date), style: TextStyle(color: dim, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _pretty(String iso) {
    final p = iso.split('-');
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${m[int.parse(p[1]) - 1]} ${int.parse(p[2])}';
  }
}

class _BarPainter extends CustomPainter {
  final List<double> values;
  final double max;
  final int? selected;
  final Color grid;
  _BarPainter(this.values, this.max, this.selected, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = grid..strokeWidth = 1;
    for (var i = 1; i <= 4; i++) {
      final y = size.height - size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), gridPaint);
    final n = values.length;
    final slot = size.width / n;
    final gap = slot > 6 ? 2.0 : (slot > 3 ? 1.0 : 0.0);
    final bar = Paint()..color = _mark;
    final barSel = Paint()..color = Colors.white;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v <= 0) continue;
      final h = size.height * v / max;
      final rect = Rect.fromLTWH(i * slot + gap / 2, size.height - h, slot - gap, h);
      final r = RRect.fromRectAndCorners(rect,
          topLeft: Radius.circular(slot > 4 ? 2 : 0), topRight: Radius.circular(slot > 4 ? 2 : 0));
      canvas.drawRRect(r, i == selected ? barSel : bar);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.values != values || old.selected != selected || old.max != max;
}
