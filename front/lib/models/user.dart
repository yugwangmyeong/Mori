class AppUser {
  final String id;
  final String? email;
  final String? name;
  final String? profileImageUrl;
  final String provider;

  AppUser({
    required this.id,
    this.email,
    this.name,
    this.profileImageUrl,
    required this.provider,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      email: json['email'] as String?,
      name: json['name'] as String?,
      profileImageUrl: json['profileImageUrl'] as String?,
      provider: json['provider'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'name': name,
      'profileImageUrl': profileImageUrl,
      'provider': provider,
    };
  }
}

