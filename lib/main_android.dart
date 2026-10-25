import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

void main() => runApp(const YtMusicApp());

class YtMusicApp extends StatelessWidget {
  const YtMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const YtMusicPage(),
    );
  }
}

class YtMusicPage extends StatefulWidget {
  const YtMusicPage({super.key});

  @override
  State<YtMusicPage> createState() => _YtMusicPageState();
}

class _YtMusicPageState extends State<YtMusicPage> {
  final _controller = WebviewController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _controller.initialize();
    await _controller.setBackgroundColor(Colors.black);
    // Keep any popups (e.g. Google sign-in) inside the same window
    await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
    await _controller.loadUrl('https://music.youtube.com');
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _controller.value.isInitialized
          ? Webview(_controller)
          : const Center(child: CircularProgressIndicator()),
    );
  }
}