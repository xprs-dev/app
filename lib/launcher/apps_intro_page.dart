import 'package:flutter/material.dart';

/// The first thing a new person sees after creating their station: what the
/// three wapps on the home screen are for. Status, Chat and Mesh are the ones
/// held on the home bars (LaunchCountStore.kDefaultModuleWapps), so each page
/// names a thing the person will find there the moment they finish.
///
/// Shown once, on a profile with no launch history (launcher_app.dart). Skip
/// is always there; nothing here is required to use the app.
class AppsIntroPage extends StatefulWidget {
  final VoidCallback onDone;

  const AppsIntroPage({super.key, required this.onDone});

  @override
  State<AppsIntroPage> createState() => _AppsIntroPageState();
}

class _IntroCard {
  final IconData icon;
  final Color color;
  final String title;
  final String lead;
  final List<String> points;

  const _IntroCard(this.icon, this.color, this.title, this.lead, this.points);
}

const _cards = [
  _IntroCard(
    Icons.campaign_outlined,
    Color(0xFF16A34A),
    'Status',
    'Say what you are up to, to everyone around you.',
    [
      'Write a short status and it goes out on every radio this device has, '
          'no internet needed.',
      'Read the statuses of the people nearby, and follow the ones you want '
          'to hear from first.',
      'The people you chat with show their newest status at the top of Chat.',
    ],
  ),
  _IntroCard(
    Icons.chat_bubble_outline,
    Color(0xFFB71C1C),
    'Chat',
    'Talk to the people around you, in groups or one to one.',
    [
      'Local chat is everyone within radio range. It is always there.',
      'Start a private chat with a station by its callsign. It is sealed once '
          'both keys are known.',
      'Groups are named rooms. Closed groups are for their members only.',
    ],
  ),
  _IntroCard(
    Icons.hub_outlined,
    Color(0xFFC0392B),
    'Mesh',
    'See who is within reach, and how.',
    [
      'A live map of the stations and devices this one can hear.',
      'Shows whether someone is reached over Bluetooth, the local network '
          'or the internet.',
      'Manage the hubs your station connects through.',
    ],
  ),
];

class _AppsIntroPageState extends State<AppsIntroPage> {
  final _pages = PageController();
  int _at = 0;

  bool get _last => _at == _cards.length - 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_last) {
      widget.onDone();
      return;
    }
    _pages.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: TextButton(
                  onPressed: widget.onDone,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: _cards.length,
                onPageChanged: (i) => setState(() => _at = i),
                itemBuilder: (context, i) => _page(theme, _cards[i]),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _cards.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _at ? 20 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _at
                          ? _cards[_at].color
                          : cs.onSurface.withAlpha(60),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: SizedBox(
                width: 480,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _cards[_at].color,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _next,
                  child: Text(_last ? 'Get started' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _page(ThemeData theme, _IntroCard c) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: c.color,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(c.icon, color: Colors.white, size: 38),
              ),
              const SizedBox(height: 24),
              Text(
                c.title,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                c.lead,
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              for (final p in c.points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(Icons.check_circle,
                            size: 18, color: c.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(p, style: theme.textTheme.bodyLarge),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'You will find ${c.title} on your home screen.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
