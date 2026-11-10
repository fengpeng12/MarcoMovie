import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import 'apple_theme.dart';

/// Variable-height source rows keep the complete name readable at large text sizes.
class SourceChoiceSliver extends StatelessWidget {
  final List<CmsSite> sites;
  final String? selectedKey;
  final String Function(CmsSite) badgeLabel;
  final Color Function(CmsSite) badgeColor;
  final ValueChanged<CmsSite> onSelected;
  final String preferredKey;
  final ValueChanged<CmsSite>? onPreferred;

  const SourceChoiceSliver({
    super.key,
    required this.sites,
    required this.selectedKey,
    required this.badgeLabel,
    required this.badgeColor,
    required this.onSelected,
    this.preferredKey = '',
    this.onPreferred,
  });

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final effectiveScale = scale < 1.0 ? 1.0 : scale;
      final columns = scale > 1.35
          ? 1
          : (constraints.crossAxisExtent / (190 * effectiveScale))
                .floor()
                .clamp(1, 3);
      return SliverList.builder(
        itemCount: (sites.length / columns).ceil(),
        itemBuilder: (context, row) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var col = 0; col < columns; col++) ...[
                if (col > 0) const SizedBox(width: 10),
                Expanded(
                  child: row * columns + col >= sites.length
                      ? const SizedBox()
                      : _card(context, sites[row * columns + col]),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _card(BuildContext context, CmsSite site) {
    final selected = site.key == selectedKey;
    final color = badgeColor(site);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: ApplePressableScale(
          pressedScale: 0.95,
          pressedOpacity: 0.88,
          onTap: () => onSelected(site),
          child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10.5),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: selected
                  ? const [Color(0x4A0A84FF), Color(0x280055B3)]
                  : const [Color(0x36FFFFFF), Color(0x1E1C1C24)],
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? const Color(0xCC3E9BFF)
                  : const Color(0x36FFFFFF),
              width: selected ? 1.2 : 0.75,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      site.name,
                      softWrap: true,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (onPreferred != null)
                    IconButton(
                      key: ValueKey('source-preference-${site.key}'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      iconSize: 17,
                      tooltip: preferredKey == site.key
                          ? '取消默认偏好源'
                          : '设为默认偏好源',
                      onPressed: () => onPreferred!(site),
                      icon: Icon(
                        preferredKey == site.key
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: preferredKey == site.key
                            ? Colors.amber
                            : AppleColors.labelSecondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (selected)
                    const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: AppleColors.systemBlue,
                      size: 15,
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .22),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: color.withValues(alpha: .45),
                        width: 0.6,
                      ),
                    ),
                    child: Text(
                      badgeLabel(site),
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    site.group.trim().isEmpty ? '默认分组' : site.group,
                    style: const TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
