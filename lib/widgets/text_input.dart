import 'package:flutter/material.dart';

class InstructionInput extends StatefulWidget {
  @override
  _InstructionInputState createState() => _InstructionInputState();
}

class _InstructionInputState extends State<InstructionInput> {
  final TextEditingController _controller = TextEditingController();
  String? userInstruction;

  void _submitInstruction() {
    setState(() {
      userInstruction = _controller.text;
    });

    if (userInstruction != null && userInstruction!.isNotEmpty) {
      print("📝 User instruction: $userInstruction");

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Instruction submitted: $userInstruction")),
      );

      _controller.clear(); // clear the field after submit
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Input field
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: "Enter your instruction",
              border: OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(Icons.send),
                onPressed: _submitInstruction,
              ),
            ),
          ),
        ),

        SizedBox(height: 20),

        // Show submitted instruction
        if (userInstruction != null)
          Text(
            "Last instruction: $userInstruction",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
      ],
    );
  }
}
