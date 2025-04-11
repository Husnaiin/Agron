import 'package:flutter/material.dart';
import 'dart:math';

class EmergencyPuzzle extends StatefulWidget {
  final VoidCallback onPuzzleSolved;

  const EmergencyPuzzle({
    super.key,
    required this.onPuzzleSolved,
  });

  @override
  State<EmergencyPuzzle> createState() => _EmergencyPuzzleState();
}

class _EmergencyPuzzleState extends State<EmergencyPuzzle> {
  late final int _firstNumber;
  late final int _secondNumber;
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    final random = Random();
    _firstNumber = random.nextInt(20) + 1;
    _secondNumber = random.nextInt(20) + 1;
  }

  void _checkAnswer() {
    final answer = int.tryParse(_controller.text);
    if (answer == null) {
      setState(() => _error = 'Please enter a valid number');
      return;
    }

    if (answer == _firstNumber + _secondNumber) {
      widget.onPuzzleSolved();
    } else {
      setState(() => _error = 'Incorrect answer, please try again');
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Emergency Stop Confirmation',
        style: TextStyle(color: Colors.red),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'To confirm emergency stop, please solve this simple puzzle:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Text(
            'What is $_firstNumber + $_secondNumber?',
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: 'Enter your answer',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _checkAnswer(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _checkAnswer,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: const Text('Confirm Stop'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
} 