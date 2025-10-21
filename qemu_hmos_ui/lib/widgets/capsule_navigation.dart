import 'package:flutter/material.dart';

/// 胶囊导航栏项
class CapsuleNavItem {
  final IconData icon;
  final String label;

  const CapsuleNavItem({
    required this.icon,
    required this.label,
  });
}

/// 胶囊导航栏组件
class CapsuleNavigation extends StatefulWidget {
  final List<CapsuleNavItem> items;
  final int currentIndex;
  final Function(int) onTap;
  final double? width;
  final double? height;

  const CapsuleNavigation({
    Key? key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.width,
    this.height,
  }) : super(key: key);

  @override
  State<CapsuleNavigation> createState() => _CapsuleNavigationState();
}

class _CapsuleNavigationState extends State<CapsuleNavigation>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _animationController.forward();
  }

  @override
  void didUpdateWidget(CapsuleNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _animationController.reset();
      _animationController.forward();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width ?? 320,
      height: widget.height ?? 70,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(40),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(
            widget.items.length,
            (index) => _buildNavItem(context, widget.items[index], index),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, CapsuleNavItem item, int index) {
    final isSelected = index == widget.currentIndex;
    
    return GestureDetector(
      onTap: () => widget.onTap(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withOpacity(0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              item.icon,
              size: 24,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

