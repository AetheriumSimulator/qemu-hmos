import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qemu_hmos/utils/harmony_performance_optimizer.dart';

/// 鑳跺泭瀵艰埅鏍忕粍浠?/// 鍏锋湁鎮诞鏁堟灉鍜屽渾瑙掕璁＄殑瀵艰埅鏍?class CapsuleNavigation extends StatefulWidget {
  final List<CapsuleNavItem> items;
  final int currentIndex;
  final Function(int) onTap;
  final CapsulePosition position;
  final CapsuleStyle style;
  final double? width;
  final double? height;

  const CapsuleNavigation({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.position = CapsulePosition.bottom,
    this.style = CapsuleStyle.auto,
    this.width,
    this.height,
  });

  @override
  State<CapsuleNavigation> createState() => _CapsuleNavigationState();
}

class _CapsuleNavigationState extends State<CapsuleNavigation>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;

  // 鎸囩ず鍣ㄥ嚑浣曚笌娴嬮噺鎵€闇€鐨刱eys
  final GlobalKey _trackKey = GlobalKey();
  late List<GlobalKey> _itemKeys;
  double _indicatorLeft = 0;
  double _indicatorWidth = 0;
  
  // 闃叉姈鏈哄埗锛岄伩鍏嶉绻侀噸寤?  Timer? _debounceTimer;
  final bool _isLayoutStable = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: HarmonyPerformanceOptimizer.getOptimizedDuration(
        const Duration(milliseconds: 300),
      ),
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: HarmonyPerformanceOptimizer.getOptimizedCurve(Curves.easeInOut),
    );
    _itemKeys = List<GlobalKey>.generate(widget.items.length, (_) => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndUpdate());
    _animationController.forward();
  }

  @override
  void didUpdateWidget(CapsuleNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex ||
        oldWidget.items.length != widget.items.length) {
      if (oldWidget.items.length != widget.items.length) {
        _itemKeys = List<GlobalKey>.generate(widget.items.length, (_) => GlobalKey());
      }
      _animationController.reset();
      _animationController.forward();
      // 寤惰繜娴嬮噺锛岀‘淇濆竷灞€瀹屾垚鍚庡啀娴嬮噺
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndUpdate());
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _measureAndUpdate() {
    try {
      final BuildContext? trackCtx = _trackKey.currentContext;
      if (trackCtx == null) return;
      final RenderBox? trackBox = trackCtx.findRenderObject() as RenderBox?;
      if (trackBox == null) return;

      if (widget.currentIndex < 0 || widget.currentIndex >= _itemKeys.length) return;
      final BuildContext? itemCtx = _itemKeys[widget.currentIndex].currentContext;
      if (itemCtx == null) return;
      final RenderBox? itemBox = itemCtx.findRenderObject() as RenderBox?;
      if (itemBox == null) return;

      final Offset itemTopLeft = itemBox.localToGlobal(Offset.zero, ancestor: trackBox);
      final double newLeft = itemTopLeft.dx;
      final double newWidth = itemBox.size.width;

      if (mounted) {
        setState(() {
          _indicatorLeft = newLeft;
          _indicatorWidth = newWidth;
        });
      }
    } catch (e) {
      // 濡傛灉娴嬮噺澶辫触锛屼娇鐢ㄩ粯璁ゅ€?      if (mounted) {
        setState(() {
          _indicatorLeft = 0;
          _indicatorWidth = 100;
        });
      }
    }
  }



  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width ?? _getDefaultWidth(context),
      height: widget.height ?? _getDefaultHeight(),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(50), // 澧炲姞鍦嗚鏇茬巼鍒?0px
        boxShadow: HarmonyPerformanceOptimizer.getOptimizedShadows(
          color: Colors.black.withOpacity(0.08),
          blurRadius: 24,
          offset: const Offset(0, 8),
          spreadRadius: 0,
        ),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.08),
          width: 1,
        ),
      ),
      child: _buildContent(context),
    );
  }

  // 璁＄畻鏂囧瓧瀹為檯瀹藉害
  double _measureTextWidth(BuildContext context, String text) {
    const TextStyle style = TextStyle(fontSize: 15, fontWeight: FontWeight.w500);
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  // 璁＄畻鍐呭鎬诲搴?= 鎵€鏈夋寜閽?鏂囧瓧瀹藉害 + 宸﹀彸padding32) + 鎸夐挳闂磋窛(15 * (n-1)) + 澶栧眰宸﹀彸鍚?
  double _computeContentWidth(BuildContext context) {
    if (widget.items.isEmpty) return 0;
    double total = 10; // 宸﹀彸鍚?
    for (int i = 0; i < widget.items.length; i++) {
      final String label = widget.items[i].label ?? '';
      total += 32 + _measureTextWidth(context, label);
      if (i < widget.items.length - 1) total += 15; // 鎸夐挳闂磋窛
    }
    // 娣诲姞棰濆鐨勫畨鍏ㄨ竟璺濓紝閬垮厤婧㈠嚭
    return total + 20;
  }

  Widget _buildContent(BuildContext context) {
    final actualStyle = widget.style == CapsuleStyle.auto ? _getAutoStyle() : widget.style;
    
    if (actualStyle == CapsuleStyle.horizontal) {
      // 姘村钩甯冨眬 - 妯悜鑳跺泭锛堟樉绀烘枃瀛楋級
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5), // 宸﹀彸杈硅窛5px
        child: Stack(
          key: _trackKey,
          children: [
            // 绉诲姩鐨勮摑鑹茶儗鏅紙浣跨敤瀹炴祴鍑犱綍锛夛紝涓婁笅宸﹀彸鍚?px鐣欑櫧
            // 娉ㄦ剰锛氬簳閮ㄤ綅缃紙鎵嬫満鐗堬級涓嶆樉绀烘粦鍔ㄨ儗鏅紝鍙樉绀烘寜閽唴閮ㄨ儗鏅?            if (widget.position != CapsulePosition.bottom)
              AnimatedPositioned(
                duration: HarmonyPerformanceOptimizer.getOptimizedDuration(
                  const Duration(milliseconds: 300),
                ),
                curve: HarmonyPerformanceOptimizer.getOptimizedCurve(Curves.easeInOut),
                left: math.max(0, _indicatorLeft - 5),
                top: 5,
                bottom: 5,
                width: _indicatorWidth + 10,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            // 鎸夐挳鍐呭锛堟暣浣撳眳涓紝鏍规嵁浣嶇疆鍐冲畾鏄剧ず鍥炬爣杩樻槸鏂囧瓧锛?            Center(  // 娣诲姞Center纭繚Row鍨傜洿灞呬腑
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,  // 璁㏑ow鏍规嵁鍐呭澶у皬鏀剁缉
                children: List.generate(
                widget.items.length,
                (index) {
                  final widgets = <Widget>[];
                  // 搴曢儴浣嶇疆鏄剧ず鍥炬爣锛岄《閮ㄤ綅缃樉绀烘枃瀛?                  if (widget.position == CapsulePosition.bottom) {
                    widgets.add(_buildIconOnlyItem(
                      context,
                      widget.items[index],
                      index,
                      index == widget.currentIndex,
                    ));
                  } else {
                    widgets.add(_buildTextOnlyItem(
                      context,
                      widget.items[index],
                      index,
                      key: index < _itemKeys.length ? _itemKeys[index] : null,
                    ));
                  }
                  if (index < widget.items.length - 1) {
                    widgets.add(const SizedBox(width: 15));
                  }
                  return widgets;
                },
              ).expand((x) => x).toList(),
              ),
            ),
          ],
        ),
      );
    } else {
      // 鍨傜洿甯冨眬 - 绔栧悜鑳跺泭锛堟樉绀哄浘鏍囷級
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: widget.items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          final isSelected = index == widget.currentIndex;
          
          return _buildIconOnlyItem(context, item, index, isSelected);
        }).toList(),
      );
    }
  }

  Widget _buildIconOnlyItem(BuildContext context, CapsuleNavItem item, int index, bool isSelected) {
    return GestureDetector(
      onTap: () => widget.onTap(index),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected 
              ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(24), // 澧炲姞鍐呴儴椤圭洰鍦嗚
        ),
        child: Icon(
          item.icon,
          color: isSelected 
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
          size: 24,
        ),
      ),
    );
  }

  Widget _buildTextOnlyItem(BuildContext context, CapsuleNavItem item, int index, {Key? key}) {
    return GestureDetector(
      onTap: () => widget.onTap(index),
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Center(  // 娣诲姞Center纭繚鏂囧瓧鍨傜洿灞呬腑
          child: Text(
            item.label ?? '',
            style: TextStyle(
              fontSize: 15,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              fontWeight: FontWeight.w500,
              height: 1.0,  // 璁剧疆琛岄珮涓?.0锛岄伩鍏嶉澶栫殑琛岄珮绌洪棿
            ),
          ),
        ),
      ),
    );
  }

  // 璁＄畻閫変腑椤圭殑浣嶇疆
  double _getSelectedItemLeft() {
    switch (widget.currentIndex) {
      case 0: // 涓婚〉
        return 0;
      case 1: // 娓告垙搴?        return 62 + 15; // 涓婚〉瀹藉害 + 闂磋窛
      case 2: // Marketplace
        return 62 + 15 + 77 + 15; // 涓婚〉 + 闂磋窛 + 娓告垙搴?+ 闂磋窛
      case 3: // 鑱婂ぉ
        return 62 + 15 + 77 + 15 + 182 + 15; // 鍓嶉潰鎵€鏈夋寜閽?+ 闂磋窛
      case 4: // 鎴戠殑
        return 62 + 15 + 77 + 15 + 182 + 15 + 62 + 15; // 鍓嶉潰鎵€鏈夋寜閽?+ 闂磋窛
      default:
        return 0;
    }
  }

  // 璁＄畻閫変腑椤圭殑瀹藉害
  double _getSelectedItemWidth() {
    switch (widget.currentIndex) {
      case 0: // 涓婚〉
        return 62;
      case 1: // 娓告垙搴?        return 77;
      case 2: // Marketplace
        return 182;
      case 3: // 鑱婂ぉ
        return 62;
      case 4: // 鎴戠殑
        return 62;
      default:
        return 62;
    }
  }

  CapsuleStyle _getAutoStyle() {
    switch (widget.position) {
      case CapsulePosition.left:
      case CapsulePosition.right:
        return CapsuleStyle.vertical; // 宸﹀彸浣嶇疆鐢ㄥ瀭鐩村竷灞€
      case CapsulePosition.top:
        return CapsuleStyle.horizontal; // 椤堕儴浣嶇疆鐢ㄦ按骞冲竷灞€锛堟í鍚戣兌鍥婏級
      case CapsulePosition.bottom:
        return CapsuleStyle.horizontal; // 搴曢儴浣嶇疆鐢ㄦ按骞冲竷灞€
      default:
        return CapsuleStyle.horizontal; // 榛樿姘村钩甯冨眬
    }
  }

  double _getDefaultWidth(BuildContext context) {
    switch (widget.position) {
      case CapsulePosition.left:
      case CapsulePosition.right:
        return 100; // 鍨傜洿鑳跺泭瀹藉害
      case CapsulePosition.top:
        // 椤堕儴鑳跺泭锛氫娇鐢ㄦ洿绱у噾鐨勫搴︼紝鍑忓皯鎮诞杈硅窛
        final contentWidth = _computeContentWidth(context);
        // 鍑忓皯棰濆鐨勮竟璺濓紝璁╄兌鍥婃洿绱у噾
        return contentWidth + 20; // 宸﹀彸鍚?0px
      case CapsulePosition.bottom:
        return MediaQuery.of(context).size.width * 0.8; // 鎵嬫満绔兌鍥婂搴?0%
      default:
        return _computeContentWidth(context);
    }
  }

  double _getDefaultHeight() {
    switch (widget.position) {
      case CapsulePosition.left:
      case CapsulePosition.right:
        return 400; // 鍨傜洿鑳跺泭楂樺害
      case CapsulePosition.top:
        return 56; // 澶у睆绔兌鍥婃洿灏忥紝楂樺害56px
      case CapsulePosition.bottom:
        return 70; // 搴曢儴鑳跺泭楂樺害70px
      default:
        return 56; // 榛樿澶у睆绔兌鍥婇珮搴?    }
  }

  double _getLeftPosition(BuildContext context) {
    switch (widget.position) {
      case CapsulePosition.left:
        return 20;
      case CapsulePosition.right:
        return MediaQuery.of(context).size.width - 120;
      case CapsulePosition.top:
        // 澶у睆绔兌鍥婂眳涓樉绀猴紝閫氳繃鍐呴儴padding鎺у埗杈硅窛
        return (MediaQuery.of(context).size.width - _getDefaultWidth(context)) / 2;
      case CapsulePosition.bottom:
        return (MediaQuery.of(context).size.width - (widget.width ?? 0)) / 2;
      default:
        return (MediaQuery.of(context).size.width - _getDefaultWidth(context)) / 2; // 榛樿灞呬腑
    }
  }

  double? _getRightPosition(BuildContext context) {
    switch (widget.position) {
      case CapsulePosition.left:
      case CapsulePosition.right:
        return null;
      case CapsulePosition.top:
        return null; // 澶у睆绔兌鍥婁笉浣跨敤right瀹氫綅锛屼娇鐢╨eft + width瀹炵幇灞呬腑
      case CapsulePosition.bottom:
        return null; // 涓嶄娇鐢╮ight瀹氫綅
      default:
        return null; // 榛樿涓嶄娇鐢╮ight瀹氫綅
    }
  }

  double _getTopPosition(BuildContext context) {
    switch (widget.position) {
      case CapsulePosition.top:
        return 20; // 澶у睆绔兌鍥婃洿璐磋繎椤堕儴
      case CapsulePosition.bottom:
        return MediaQuery.of(context).size.height - 120;
      case CapsulePosition.left:
      case CapsulePosition.right:
        return (MediaQuery.of(context).size.height - _getDefaultHeight()) / 2;
      default:
        return (MediaQuery.of(context).size.height - _getDefaultHeight()) / 2;
    }
  }

  double? _getBottomPosition(BuildContext context) {
    switch (widget.position) {
      case CapsulePosition.top:
      case CapsulePosition.bottom:
        return null;
      case CapsulePosition.left:
      case CapsulePosition.right:
        return (MediaQuery.of(context).size.height - _getDefaultHeight()) / 2;
      default:
        return (MediaQuery.of(context).size.height - _getDefaultHeight()) / 2;
    }
  }

  EdgeInsets _getMargin() {
    switch (widget.position) {
      case CapsulePosition.top:
        return const EdgeInsets.only(top: 16); // 鍑忓皯椤堕儴杈硅窛
      case CapsulePosition.bottom:
        return const EdgeInsets.only(bottom: 20);
      case CapsulePosition.left:
        return const EdgeInsets.only(left: 20);
      case CapsulePosition.right:
        return const EdgeInsets.only(right: 20);
      default:
        return const EdgeInsets.only(bottom: 20);
    }
  }
}

/// 鑳跺泭瀵艰埅椤圭洰
class CapsuleNavItem {
  final IconData icon;
  final String? label;
  final VoidCallback? onTap;

  const CapsuleNavItem({
    required this.icon,
    this.label,
    this.onTap,
  });
}

/// 鑳跺泭浣嶇疆鏋氫妇
enum CapsulePosition {
  top,      // 椤堕儴
  bottom,   // 搴曢儴
  left,     // 宸︿晶
  right,    // 鍙充晶
}

/// 鑳跺泭鏍峰紡鏋氫妇
enum CapsuleStyle {
  auto,         // 鑷姩閫夋嫨
  horizontal,   // 姘村钩甯冨眬锛堟枃瀛楋級
  vertical,     // 鍨傜洿甯冨眬锛堝浘鏍囷級
}

/// 鍝嶅簲寮忚兌鍥婂鑸爮
class ResponsiveCapsuleNavigation extends StatelessWidget {
  final List<CapsuleNavItem> items;
  final int currentIndex;
  final Function(int) onTap;
  final double? width;
  final double? height;

  const ResponsiveCapsuleNavigation({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;
        
        // 鏇寸ǔ瀹氱殑鍝嶅簲寮忓垽鏂紝閬垮厤棰戠箒鍒囨崲
        CapsulePosition position;
        CapsuleStyle style;
        
        // 浣跨敤鏇翠繚瀹堢殑闃堝€硷紝閬垮厤鍦ㄨ竟鐣屽€奸檮杩戦绻佸垏鎹?        if (screenWidth > 800) {
          // 澶у睆璁惧锛堝钩鏉裤€佹闈級- 濮嬬粓浣跨敤椤堕儴鑳跺泭
          position = CapsulePosition.top;
          style = CapsuleStyle.horizontal;
        } else if (screenWidth > 600) {
          // 涓瓑灞忓箷 - 涔熶娇鐢ㄩ《閮ㄨ兌鍥婏紝淇濇寔涓€鑷存€?          position = CapsulePosition.top;
          style = CapsuleStyle.horizontal;
        } else {
          // 鍙湁鐪熸鐨勫皬灞忔墜鏈烘墠浣跨敤搴曢儴鑳跺泭
          position = CapsulePosition.bottom;
          style = CapsuleStyle.vertical;
        }
        
        // 璁＄畻鑳跺泭鐨勫悎閫傚搴︼紝纭繚鎮诞鏁堟灉
        double? capsuleWidth;
        if (position == CapsulePosition.top) {
          // 椤堕儴鑳跺泭锛氫娇鐢ㄦ洿绱у噾鐨勫搴︼紝鍑忓皯鎮诞杈硅窛
          // 浼扮畻鍐呭瀹藉害锛?涓寜閽?* (骞冲潎鏂囧瓧瀹藉害 + 16px) + 4涓棿璺?* 15px + 宸﹀彸鍚?px
          const estimatedContentWidth = 5 * (60 + 16) + 4 * 15 + 10;
          capsuleWidth = estimatedContentWidth.toDouble();
        } else if (position == CapsulePosition.bottom) {
          // 搴曢儴鑳跺泭锛氫娇鐢?0%灞忓箷瀹藉害
          capsuleWidth = screenWidth * 0.8;
        }
        
        return Center(
          child: CapsuleNavigation(
            items: items,
            currentIndex: currentIndex,
            onTap: onTap,
            position: position,
            style: style,
            width: capsuleWidth,
            height: height,
          ),
        );
      },
    );
  }
}
