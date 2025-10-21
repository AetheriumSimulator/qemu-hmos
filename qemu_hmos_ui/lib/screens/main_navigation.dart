import 'package:flutter/material.dart';
import '../widgets/capsule_navigation.dart';
import 'vm_list_screen.dart';
import 'apps_screen.dart';
import 'profile_screen.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({Key? key}) : super(key: key);

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const VmListScreen(),
    const AppsScreen(),
    const ProfileScreen(),
  ];

  final List<CapsuleNavItem> _navItems = [
    const CapsuleNavItem(icon: Icons.computer, label: '虚拟机'),
    const CapsuleNavItem(icon: Icons.apps, label: 'Apps'),
    const CapsuleNavItem(icon: Icons.person, label: '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 主内容区域，添加底部边距避让胶囊
          Padding(
            padding: const EdgeInsets.only(bottom: 100), // 避让底部胶囊
            child: IndexedStack(
              index: _currentIndex,
              children: _pages,
            ),
          ),
          // 底部胶囊导航栏
          Positioned(
            left: 0,
            right: 0,
            bottom: 20,
            child: Center(
              child: CapsuleNavigation(
                items: _navItems,
                currentIndex: _currentIndex,
                onTap: (index) {
                  setState(() {
                    _currentIndex = index;
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

