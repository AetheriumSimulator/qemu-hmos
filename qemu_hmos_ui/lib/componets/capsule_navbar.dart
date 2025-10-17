import 'package:flutter/material.dart';

class CapsuleNavbar extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final VoidCallback? onBackPressed;

  const CapsuleNavbar({
    super.key,
    required this.title,
    this.actions,
    this.onBackPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey[300]!,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          if (onBackPressed != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_ios),
              onPressed: onBackPressed,
            ),
          
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          
          if (actions != null) ...actions!,
        ],
      ),
    );
  }
}
