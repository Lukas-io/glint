import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'activity.dart';

enum RidePhase { choosing, searching, matched, rating, done }

class RideState {
  const RideState({this.phase = RidePhase.choosing, this.option = 'Economy', this.fare = 2500, this.stars = 0});
  final RidePhase phase;
  final String option;
  final int fare;
  final int stars;

  RideState copyWith({RidePhase? phase, String? option, int? fare, int? stars}) =>
      RideState(phase: phase ?? this.phase, option: option ?? this.option, fare: fare ?? this.fare, stars: stars ?? this.stars);
}

class RideCubit extends Cubit<RideState> {
  RideCubit() : super(const RideState());
  Timer? _match;

  static const options = {'Economy': 2500, 'Comfort': 3400, 'XL': 4800};

  void choose(String option) => emit(state.copyWith(option: option, fare: options[option]));
  void bump(int by) => emit(state.copyWith(fare: (state.fare + by).clamp(options[state.option]!, 20000)));

  void find() {
    emit(state.copyWith(phase: RidePhase.searching));
    _match = Timer(const Duration(seconds: 3), () => emit(state.copyWith(phase: RidePhase.matched)));
  }

  void cancel() {
    _match?.cancel();
    emit(state.copyWith(phase: RidePhase.choosing));
  }

  void arrive() => emit(state.copyWith(phase: RidePhase.rating));
  void rate(int stars) => emit(state.copyWith(stars: stars));

  void submit() {
    logActivity('Rode ${state.option} for ₦${state.fare}, rated ${state.stars}');
    emit(state.copyWith(phase: RidePhase.done));
  }

  @override
  Future<void> close() {
    _match?.cancel();
    return super.close();
  }
}

class RideScreen extends StatelessWidget {
  const RideScreen({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(create: (_) => RideCubit(), child: const _RideView());
}

class _RideView extends StatelessWidget {
  const _RideView();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: CustomPaint(painter: _MapPainter())),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Material(
                  borderRadius: BorderRadius.circular(12),
                  elevation: 2,
                  child: const ListTile(leading: Icon(Icons.trip_origin), title: Text('Lekki Phase 1'), subtitle: Text('to Victoria Island · 14 min')),
                ),
              ),
            ),
            BlocBuilder<RideCubit, RideState>(
              builder: (context, s) => switch (s.phase) {
                RidePhase.choosing => const _Options(),
                RidePhase.searching => const _Searching(),
                RidePhase.matched => const _Driver(),
                RidePhase.rating => const _Rating(),
                RidePhase.done => const Align(alignment: Alignment.bottomCenter, child: Card(child: ListTile(title: Text('Thanks for riding')))),
              },
            ),
          ],
        ),
      );
}

/// A drawn map, standing in for a map SDK that renders outside Flutter's tree.
class _MapPainter extends CustomPainter {
  const _MapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE8EFE6));
    final road = Paint()
      ..color = Colors.white
      ..strokeWidth = 14;
    for (var i = 1; i < 6; i++) {
      canvas.drawLine(Offset(0, size.height * i / 6), Offset(size.width, size.height * i / 6 - 40), road);
      canvas.drawLine(Offset(size.width * i / 6, 0), Offset(size.width * i / 6 + 30, size.height), road);
    }
    canvas.drawCircle(Offset(size.width * .4, size.height * .35), 10, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Options extends StatelessWidget {
  const _Options();

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        initialChildSize: .45,
        minChildSize: .3,
        maxChildSize: .8,
        builder: (context, controller) {
          final s = context.watch<RideCubit>().state;
          final cubit = context.read<RideCubit>();
          return Material(
            elevation: 8,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.all(16),
              children: [
                for (final MapEntry(key: name, value: fare) in RideCubit.options.entries)
                  Card(
                    shape: RoundedRectangleBorder(
                      side: BorderSide(color: s.option == name ? Colors.black : Colors.transparent, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: InkWell(
                      onTap: () => cubit.choose(name),
                      child: ListTile(leading: const Icon(Icons.directions_car), title: Text(name), subtitle: const Text('4 min away'), trailing: Text('₦$fare')),
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.outlined(onPressed: () => cubit.bump(-100), icon: const Icon(Icons.remove), tooltip: 'Lower fare'),
                    Padding(padding: const EdgeInsets.all(16), child: Text('₦${s.fare}', style: Theme.of(context).textTheme.titleLarge)),
                    IconButton.outlined(onPressed: () => cubit.bump(100), icon: const Icon(Icons.add), tooltip: 'Raise fare'),
                  ],
                ),
                FilledButton(onPressed: cubit.find, child: const Text('Find a driver')),
              ],
            ),
          );
        },
      );
}

class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.bottomCenter,
        child: Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Looking for a driver near you'),
              const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
              TextButton(onPressed: context.read<RideCubit>().cancel, child: const Text('Cancel request')),
            ]),
          ),
        ),
      );
}

class _Driver extends StatelessWidget {
  const _Driver();

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.bottomCenter,
        child: Card(
          margin: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const ListTile(title: Text('Please meet your captain'), subtitle: Text('White Toyota Corolla · LND 482 KJ')),
            ListTile(
              leading: const CircleAvatar(child: Text('EA')),
              title: const Text('Emeka A.'),
              subtitle: const Text('★ 4.9'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(onPressed: () {}, icon: const Icon(Icons.chat_outlined), tooltip: 'Message driver'),
                IconButton(onPressed: () {}, icon: const Icon(Icons.phone_outlined), tooltip: 'Call driver'),
              ]),
            ),
            TextButton(onPressed: context.read<RideCubit>().arrive, child: const Text('End trip')),
          ]),
        ),
      );
}

class _Rating extends StatelessWidget {
  const _Rating();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<RideCubit>().state;
    final cubit = context.read<RideCubit>();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Card(
        margin: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('How was your ride with Emeka?')),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 1; i <= 5; i++)
              IconButton(onPressed: () => cubit.rate(i), icon: Icon(i <= s.stars ? Icons.star : Icons.star_border), tooltip: '$i stars'),
          ]),
          FilledButton(onPressed: s.stars == 0 ? null : cubit.submit, child: const Text('Submit')),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}
