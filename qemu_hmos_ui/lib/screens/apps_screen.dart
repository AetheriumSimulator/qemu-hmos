import 'package:flutter/material.dart';

/// Apps页面 - 显示虚拟机内的应用列表
class AppsScreen extends StatefulWidget {
  const AppsScreen({Key? key}) : super(key: key);

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // 标题栏
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Apps',
                      style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '虚拟机内的应用',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[600],
                          ),
                    ),
                  ],
                ),
              ),
            ),
            
            // 应用列表
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.85,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    return _buildAppCard(context, index);
                  },
                  childCount: 6, // 示例：6个应用
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppCard(BuildContext context, int index) {
    final List<Map<String, dynamic>> apps = [
      {'name': 'Chrome', 'icon': Icons.public, 'color': Colors.blue},
      {'name': 'VS Code', 'icon': Icons.code, 'color': Colors.lightBlue},
      {'name': 'Office', 'icon': Icons.work, 'color': Colors.orange},
      {'name': 'Photos', 'icon': Icons.photo_library, 'color': Colors.green},
      {'name': 'Music', 'icon': Icons.music_note, 'color': Colors.purple},
      {'name': 'Settings', 'icon': Icons.settings, 'color': Colors.grey},
    ];

    if (index >= apps.length) return const SizedBox();

    final app = apps[index];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('启动 ${app['name']}')),
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: (app['color'] as Color).withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                app['icon'] as IconData,
                size: 32,
                color: app['color'] as Color,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              app['name'] as String,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

