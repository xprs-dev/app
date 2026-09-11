part of 'launcher.dart';

/// The temperature around this device, under the hero carousel.
///
/// A line read in passing and never opened. It shows what the stations in
/// reach measure (XPRS.md 15.3), inside and outside told apart by a house and a
/// tree, and it adds nothing when there is nothing to show: an indoor-only
/// sensor gives one reading, no sensor gives no line.
///
/// It sits in the gap between the carousel and the wapp cards and owns that
/// gap, so it costs as little height as it can. It first went above the
/// carousel, and on the C61 (360 dp wide) its extra height pushed the network
/// card under the bottom sheet.
///
/// It renders [XprsClimate.current] and decides nothing. Which station, how
/// fresh, which unit: all of that is the core's (docs/architecture.md §1). No
/// timer here either: the core drops a stale reading and this rebuilds.
class _ClimateGlance extends StatelessWidget {
  const _ClimateGlance();

  @override
  Widget build(BuildContext context) {
    // The first reading arrives while the screen is open: grow into place
    // rather than shove the carousel down in one frame.
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: ValueListenableBuilder<LocalClimate>(
        valueListenable: XprsClimate.instance.current,
        builder: (context, c, _) => c.isEmpty
            ? const SizedBox(width: double.infinity, height: _gap)
            : _line(c),
      ),
    );
  }

  /// The space the launcher had between the carousel and the cards.
  static const double _gap = 20;

  Widget _line(LocalClimate c) {
    // Tight on purpose: 6 here plus the cards' own 4 is the 10 dp the cards
    // keep between each other, so the line reads as part of that stack, and
    // on the C61 the network card stays clear of the bottom sheet.
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 6),
      child: Wrap(
        spacing: 22,
        runSpacing: 4,
        children: [
          if (c.inside != null)
            _ClimateValue(
              icon: Icons.home_outlined,
              reading: c.inside!,
              where: 'inside',
            ),
          if (c.outside != null)
            _ClimateValue(
              // Two pines, chosen by rendering the candidates at this size: one
              // pine read as a warning triangle, the round tree as a light
              // bulb, and a cloud or a sun says what the sky is doing.
              icon: Icons.forest_outlined,
              reading: c.outside!,
              where: 'outside',
            ),
        ],
      ),
    );
  }
}

class _ClimateValue extends StatelessWidget {
  final IconData icon;
  final ClimateReading reading;
  final String where;

  const _ClimateValue({
    required this.icon,
    required this.reading,
    required this.where,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Long-press says whose sensor it is; the icon and the number are all the
    // line needs. The word is still there for a screen reader, which cannot
    // see a house or a tree.
    return Tooltip(
      message: 'Measured by ${reading.station}',
      child: Semantics(
        label: '$where ${reading.label.replaceAll('°C', ' degrees Celsius')}',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Grows with the text: at a large font size a fixed icon shrank
            // beside its own number.
            Icon(icon,
                size: MediaQuery.textScalerOf(context).scale(19),
                color: cs.onSurfaceVariant),
            const SizedBox(width: 7),
            Text(
              reading.label,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
