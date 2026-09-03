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
  _Step('01  YOUR SERVER',
      'Your photos stay on your computer.',
      'Photobank runs on your own PC or Mac. This app finds it automatically on your Wi-Fi - '
      'no cloud, no account with us.'),
  _Step('02  BACKUP',
      'Back up the camera roll.',
      'Tap Back up on the Backup tab. Every photo and video is checked by fingerprint, so nothing '
      'uploads twice. Turn on Background backup to let it run while the phone charges.'),
  _Step('03  FREE UP SPACE',
      'Free space only when it is safe.',
      'Free up space removes photos from the phone that the server confirms it holds - each one is '
      'verified first. Choose how far back to keep in Settings, and let it run automatically if you like.'),
  _Step('04  LIBRARY',
      'Everything, from anywhere at home.',
      'The Library tab shows the whole server: by date or by size, albums, favorites, Live Photos. '
      'Search finds text inside photos. Save anything back to the phone with one tap.'),
  _Step('05  SETTINGS',
      'You are in control.',
      'Retention window, background backup, reminders, hidden photos, trash, and the app data on '
      'this phone all live in Settings. You can show this tour again from there.'),
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
