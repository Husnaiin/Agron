import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

class AudioRecorderButton extends StatefulWidget {
  @override
  _AudioRecorderButtonState createState() => _AudioRecorderButtonState();
}

class _AudioRecorderButtonState extends State<AudioRecorderButton> {
  final record = AudioRecorder();
  bool isRecording = false;
  String? recordedFilePath;

  Future<void> _toggleRecording() async {
    if (!isRecording) {
      // Start Recording
      if (await record.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        String path =
            '${dir.path}/my_recording_${DateTime.now().millisecondsSinceEpoch}.m4a';

        await record.start(
          const RecordConfig(),
          path: path,
        );

        setState(() {
          isRecording = true;
          recordedFilePath = path;
        });
      }
    } else {
      // Stop Recording
      final path = await record.stop();

      setState(() {
        isRecording = false;
        recordedFilePath = path;
      });

      if (path != null) {
        // ✅ Print file path to console
        print("🎙️ Recording saved successfully!");
        print("📂 File path: $path");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Recording saved at: $path")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isRecording ? Colors.red : Colors.green,
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          fixedSize: const Size(48, 48),
          minimumSize: const Size(48, 48),
          alignment: Alignment.center,
        ),
        onPressed: _toggleRecording,
        child: Icon(
          isRecording ? Icons.stop : Icons.mic,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }
}
