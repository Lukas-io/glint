import 'package:flutter/material.dart';

import 'pages/about_you.dart';
import 'pages/account.dart';
import 'pages/done.dart';
import 'pages/interests.dart';
import 'pages/photos.dart';
import 'pages/preferences.dart';
import 'pages/prompts.dart';
import 'pages/review.dart';
import 'pages/verify.dart';
import 'pages/welcome.dart';
import 'theme.dart';

void main() => runApp(const EmberApp());

class EmberApp extends StatelessWidget {
  const EmberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ember',
      debugShowCheckedModeBanner: false,
      theme: emberTheme(),
      initialRoute: '/',
      routes: {
        '/': (_) => const WelcomePage(),
        '/account': (_) => const AccountPage(),
        '/verify': (_) => const VerifyPage(),
        '/about': (_) => const AboutYouPage(),
        '/preferences': (_) => const PreferencesPage(),
        '/photos': (_) => const PhotosPage(),
        '/interests': (_) => const InterestsPage(),
        '/prompts': (_) => const PromptsPage(),
        '/review': (_) => const ReviewPage(),
        '/done': (_) => const DonePage(),
      },
    );
  }
}
