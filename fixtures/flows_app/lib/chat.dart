import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Dismissible, DismissDirection, Colors, Material;
import 'package:get/get.dart';

import 'activity.dart';

class Message {
  Message(this.text, {required this.mine});
  final String text;
  final bool mine;
}

class ChatController extends GetxController {
  final messages = <Message>[
    Message('Hey! Are we still on for Saturday?', mine: false),
    Message('Yes, 4pm at the usual place', mine: true),
    Message('Perfect. Can you bring the speaker?', mine: false),
  ].obs;
  final replyingTo = Rxn<Message>();
  final typing = false.obs;
  Timer? _reply;

  void send(String text) {
    if (text.trim().isEmpty) return;
    final quoted = replyingTo.value;
    messages.add(Message(quoted == null ? text : '↪ "${quoted.text}"\n$text', mine: true));
    replyingTo.value = null;
    typing.value = true;
    _reply = Timer(const Duration(seconds: 2), () {
      typing.value = false;
      messages.add(Message('Got it 👍', mine: false));
    });
    logActivity('Sent a chat message');
  }

  void delete(Message m) => messages.remove(m);

  @override
  void onClose() {
    _reply?.cancel();
    super.onClose();
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _c = Get.put(ChatController());
  final _input = TextEditingController();

  @override
  void dispose() {
    Get.delete<ChatController>();
    _input.dispose();
    super.dispose();
  }

  void _actions(Message m) => showCupertinoModalPopup<void>(
        context: context,
        builder: (sheet) => CupertinoActionSheet(
          title: Text(m.text, maxLines: 2),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () {
                _c.replyingTo.value = m;
                Navigator.pop(sheet);
              },
              child: const Text('Reply'),
            ),
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                _c.delete(m);
                Navigator.pop(sheet);
              },
              child: const Text('Delete'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(sheet), child: const Text('Cancel')),
        ),
      );

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('Amara')),
        child: SafeArea(
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                Expanded(
                  child: Obx(() {
                    final list = _c.messages.reversed.toList();
                    return ListView.builder(
                      reverse: true,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final m = list[i];
                        return Dismissible(
                          key: ObjectKey(m),
                          direction: m.mine ? DismissDirection.endToStart : DismissDirection.none,
                          onDismissed: (_) => _c.delete(m),
                          child: GestureDetector(
                            onLongPress: () => _actions(m),
                            child: Align(
                              alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: m.mine ? CupertinoColors.activeBlue : CupertinoColors.systemGrey5,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(m.text, style: TextStyle(color: m.mine ? CupertinoColors.white : CupertinoColors.black)),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  }),
                ),
                Obx(() => _c.typing.value ? const Padding(padding: EdgeInsets.all(4), child: Text('Amara is typing…')) : const SizedBox.shrink()),
                Obx(() {
                  final r = _c.replyingTo.value;
                  return r == null
                      ? const SizedBox.shrink()
                      : Row(children: [
                          Expanded(child: Padding(padding: const EdgeInsets.all(8), child: Text('Replying to: ${r.text}', maxLines: 1))),
                          CupertinoButton(padding: EdgeInsets.zero, onPressed: () => _c.replyingTo.value = null, child: const Icon(CupertinoIcons.xmark_circle)),
                        ]);
                }),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [
                    Expanded(child: CupertinoTextField(controller: _input, placeholder: 'Message')),
                    CupertinoButton(
                      onPressed: () {
                        _c.send(_input.text);
                        _input.clear();
                      },
                      child: const Icon(CupertinoIcons.arrow_up_circle_fill),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      );
}
