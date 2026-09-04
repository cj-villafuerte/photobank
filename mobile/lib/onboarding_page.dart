import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

/// Five-step tour shown after the first sign-in; re-openable from Settings.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  static Future<bool> isDone() async =>
      (await SharedPreferences.getInstance()).getBool('onboarded') ?? false;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _Step {
  final String eyebrow, title, body;
  const _Step(this.eyebrow, this.title, this.body);
}

const _steps = [
  _Step('01  YOUR OWN SERVER',
      'Your photos stay on your computer.',
      'Photobank runs on your own PC or Mac and this app finds it on your Wi-Fi. No cloud, no '
      'subscription, no account with anyone but yourself.'),
  _Step('02  BACK UP',
      'One tap, then it takes care of itself.',
      'Tap Back up and every photo and video goes to your server, checked by fingerprint so nothing '
      'uploads twice. Turn on Background backup and it continues while the phone charges.'),
  _Step('03  ROOM ON THE PHONE',
      'You choose how long photos stay on the phone.',
      'Keep the last month, the last year, or everything - your call, in Settings > Phone storage. '
      'Free up space then removes only photos the server has already confirmed it holds, and you '
      'approve the exact count first. Nothing is ever deleted from the phone without that.'),
  _Step('04  ONE LIBRARY',
      'Phone and server, side by side.',
      'The Library shows both together, month by month. A cloud means the photo is safe on the '
      'server; a phone icon means it is only on this phone. Switch to Server or Phone to see one '
      'side, and search to find words inside your photos - signs, receipts, screenshots.'),
  _Step('05  THE REST',
      'Everything else is in Settings.',
      'Reminders, trash, and what this app stores on the phone. Technical details sit under '
      'Advanced. Hidden photos are there too - pull up past the end of the list. You can open '
      'this tour again any time.'),
];

class _OnboardingPageState extends State<OnboardingPage> {
  final _ctrl = PageController();
  int _index = 0;

  Future<void> _finish() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('onboarded', true);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _steps.length - 1;
    return Scaffold(
      backgroundColor: PbColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
              child: Row(
                children: [
                  Text.rich(TextSpan(
                    text: 'Photobank',
                    style: pbDisplay(size: 22, weight: FontWeight.w800),
                    children: [TextSpan(text: '.', style: pbDisplay(size: 22, weight: FontWeight.w800, color: PbColors.accent))],
                  )),
                  const Spacer(),
                  TextButton(onPressed: _finish, child: Text('SKIP', style: pbMono(size: 10, color: PbColors.ink))),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _ctrl,
                itemCount: _steps.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final s = _steps[i];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(TextSpan(children: [
                          TextSpan(text: s.eyebrow.substring(0, 2), style: pbMono(size: 11, color: PbColors.accent)),
                          TextSpan(text: s.eyebrow.substring(2), style: pbMono(size: 11)),
                        ])),
                        const SizedBox(height: 18),
                        Text(s.title, style: pbDisplay(size: 34)),
                        const SizedBox(height: 18),
                        const Divider(),
                        const SizedBox(height: 18),
                        Text(s.body, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: PbColors.muted)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Row(
                children: [
                  for (var i = 0; i < _steps.length; i++)
                    Container(
                      width: i == _index ? 18 : 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: i == _index ? PbColors.ink : PbColors.line2,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: last
                        ? _finish
                        : () => _ctrl.nextPage(duration: const Duration(milliseconds: 220), curve: Curves.easeOut),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      child: Text(last ? 'Start' : 'Next  →'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
