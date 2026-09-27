class SignupData {
  String email = '';
  String password = '';
  String name = '';
  DateTime? birthday;
  String? gender;
  String? showMe;
  double distanceKm = 50;
  String? photoPath;
  final Set<String> interests = {};
  bool notifications = false;

  Map<String, Object?> toJson() => {
        'email': email,
        'name': name,
        'birthday': birthday == null
            ? null
            : '${birthday!.year}-${birthday!.month.toString().padLeft(2, '0')}-${birthday!.day.toString().padLeft(2, '0')}',
        'gender': gender,
        'showMe': showMe,
        'distanceKm': distanceKm.round(),
        'hasPhoto': photoPath != null,
        'interests': interests.toList()..sort(),
        'notifications': notifications,
      };
}

final signup = SignupData();

const months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String formatDate(DateTime d) => '${d.day} ${months[d.month - 1]} ${d.year}';
