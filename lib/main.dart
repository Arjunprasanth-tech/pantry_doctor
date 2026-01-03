import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// ---------------------------------------------------------------------------
// 🛡️ PANTRY DOCTOR: SECURE CORE
// ---------------------------------------------------------------------------
const String authorizedAppId = "pantry_chef";
const String modelName = "gemini-2.5-flash-preview-09-2025";
const Color clinicalGreen = Color(0xFF00A36C);
const String logoPath = "assets/logo.png";
// ---------------------------------------------------------------------------

Map<String, String>? _cachedDailyMeals;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Startup Failure: $e");
  }
  runApp(const PantryDoctorApp());
}

class PantryDoctorApp extends StatelessWidget {
  const PantryDoctorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PANTRY DOCTOR',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: clinicalGreen,
          primary: clinicalGreen,
          surface: const Color(0xFFFDFBF7),
        ),
        textTheme: GoogleFonts.interTextTheme(),
      ),
      home: const SplashScreen(),
    );
  }
}

class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 100});
  @override
  Widget build(BuildContext context) {
    return Image.asset(
      logoPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return Icon(Icons.health_and_safety_rounded,
            size: size, color: clinicalGreen);
      },
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AuthGate()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppLogo(size: 160),
            const SizedBox(height: 24),
            Text("PANTRY DOCTOR",
                style: GoogleFonts.playfairDisplay(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2)),
            const Text("Your AI Clinical Nutritionist",
                style: TextStyle(
                    color: Colors.grey, letterSpacing: 1.5, fontSize: 12)),
            const SizedBox(height: 60),
            const CircularProgressIndicator(strokeWidth: 2),
          ],
        ),
      ),
    );
  }
}

class ApiRotator {
  static int _currentKeyIndex = 1;

  static String get activeKey {
    return dotenv.env['GEMINI_API_KEY_$_currentKeyIndex'] ?? "";
  }

  static void _rotate() {
    _currentKeyIndex = _currentKeyIndex == 1 ? 2 : 1;
  }

  static Future<T> execute<T>(
      BuildContext context, Future<T> Function(String key) task) async {
    int attempts = 0;
    while (attempts < 2) {
      final key = activeKey;
      if (key.isEmpty) {
        _rotate();
        attempts++;
        continue;
      }

      try {
        return await task(key);
      } catch (e) {
        String err = e.toString().toLowerCase();
        if (err.contains('429') || err.contains('quota')) {
          _rotate();
          attempts++;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        _error(context, "Clinic AI Error: $e");
        rethrow;
      }
    }
    throw "All API keys are exhausted. Please wait 1 minute.";
  }

  static void _error(BuildContext context, String m) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(m), backgroundColor: Colors.redAccent));
    }
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasData && snapshot.data != null) {
          return MedicalVaultGate(user: snapshot.data!);
        }
        return const LoginScreen();
      },
    );
  }
}

class MedicalVaultGate extends StatelessWidget {
  final User user;
  const MedicalVaultGate({super.key, required this.user});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('artifacts')
          .doc(authorizedAppId)
          .collection('users')
          .doc(user.uid)
          .collection('medical_records')
          .doc('profile')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (!snapshot.hasData ||
            snapshot.data == null ||
            !snapshot.data!.exists) {
          return const MedicalOnboarding(isUpdate: false);
        }
        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null || data['diagnosis'] == null) {
          return const MedicalOnboarding(isUpdate: false);
        }
        return Dashboard(medicalData: data, user: user);
      },
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _isLogin = true;
  bool _loading = false;

  Future<void> _auth() async {
    if (_email.text.isEmpty || _pass.text.isEmpty) {
      return;
    }
    setState(() => _loading = true);
    try {
      if (_isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
            email: _email.text.trim(), password: _pass.text.trim());
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: _email.text.trim(), password: _pass.text.trim());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(40),
              child: Column(children: [
                const AppLogo(size: 100),
                const SizedBox(height: 16),
                Text("PANTRY DOCTOR",
                    style: GoogleFonts.playfairDisplay(
                        fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(height: 40),
                TextField(
                    controller: _email,
                    decoration: const InputDecoration(
                        labelText: "Clinic Email",
                        border: OutlineInputBorder())),
                const SizedBox(height: 16),
                TextField(
                    controller: _pass,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: "Security Key",
                        border: OutlineInputBorder())),
                const SizedBox(height: 40),
                _loading
                    ? const CircularProgressIndicator()
                    : ElevatedButton(
                        onPressed: _auth,
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 60),
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white),
                        child: Text(_isLogin ? "LOG IN" : "REGISTER")),
                TextButton(
                    onPressed: () => setState(() => _isLogin = !_isLogin),
                    child: Text(_isLogin
                        ? "New patient? Create account"
                        : "Back to login")),
              ]))),
    );
  }
}

class MedicalOnboarding extends StatefulWidget {
  final bool isUpdate;
  const MedicalOnboarding({super.key, required this.isUpdate});
  @override
  State<MedicalOnboarding> createState() => _MedicalOnboardingState();
}

class _MedicalOnboardingState extends State<MedicalOnboarding> {
  bool _loading = false;
  final _picker = ImagePicker();
  Future<void> _scan() async {
    final p =
        await _picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (p == null) {
      return;
    }
    setState(() => _loading = true);
    try {
      final bytes = await p.readAsBytes();
      final map = await ApiRotator.execute(context, (key) async {
        final model = GenerativeModel(
            model: modelName,
            apiKey: key,
            generationConfig:
                GenerationConfig(responseMimeType: 'application/json'));
        final res = await model.generateContent([
          Content.multi([
            TextPart(
                "JSON: diagnosis(str), avoid(list), morning(dish), lunch(dish), evening(dish)"),
            DataPart('image/jpeg', bytes)
          ])
        ]);
        return jsonDecode(
                RegExp(r'\{[\s\S]*\}').firstMatch(res.text!)!.group(0)!)
            as Map<String, dynamic>;
      });
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await FirebaseFirestore.instance
            .collection('artifacts')
            .doc(authorizedAppId)
            .collection('users')
            .doc(uid)
            .collection('medical_records')
            .doc('profile')
            .set({
          'diagnosis': map['diagnosis'],
          'avoidList': map['avoid'],
          'morning': map['morning'],
          'lunch': map['lunch'],
          'evening': map['evening'],
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      _cachedDailyMeals = null;
      if (mounted && widget.isUpdate) {
        Navigator.pop(context);
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Initialize Medical Profile")),
      body: Center(
          child: Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.verified_user_rounded,
                        size: 80, color: clinicalGreen),
                    const SizedBox(height: 24),
                    const Text("Lock Your Health Identity",
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const Text(
                        "Upload a report to build your nutrition profile.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 48),
                    _loading
                        ? const CircularProgressIndicator()
                        : ElevatedButton.icon(
                            onPressed: _scan,
                            icon: const Icon(Icons.document_scanner),
                            label: const Text("SCAN REPORT"),
                            style: ElevatedButton.styleFrom(
                                minimumSize: const Size(double.infinity, 60))),
                  ]))),
    );
  }
}

class Dashboard extends StatefulWidget {
  final Map<String, dynamic> medicalData;
  final User user;
  const Dashboard({super.key, required this.medicalData, required this.user});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  int _idx = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _idx, children: [
        KitchenPage(medicalData: widget.medicalData),
        const ForensicLab(),
        ProfilePage(medicalData: widget.medicalData, user: widget.user)
      ]),
      bottomNavigationBar: NavigationBar(
          selectedIndex: _idx,
          onDestinationSelected: (i) => setState(() => _idx = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.restaurant_rounded), label: "Kitchen"),
            NavigationDestination(
                icon: Icon(Icons.science_rounded), label: "Lab"),
            NavigationDestination(
                icon: Icon(Icons.person_pin_rounded), label: "Profile"),
          ]),
    );
  }
}

class KitchenPage extends StatefulWidget {
  final Map<String, dynamic> medicalData;
  const KitchenPage({super.key, required this.medicalData});
  @override
  State<KitchenPage> createState() => _KitchenPageState();
}

class _KitchenPageState extends State<KitchenPage> {
  final _input = TextEditingController();
  final _picker = ImagePicker();
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    // Use null-aware assignment to fix prefer_conditional_assignment diagnostic
    _cachedDailyMeals ??= {
      'Morning': widget.medicalData['morning'] ?? "Breakfast",
      'Lunch': widget.medicalData['lunch'] ?? "Lunch",
      'Evening': widget.medicalData['evening'] ?? "Dinner",
    };
  }

  Future<void> _cook({String? specificDish, ImageSource? source}) async {
    Uint8List? bytes;
    if (source != null) {
      final p = await _picker.pickImage(source: source);
      if (p == null) {
        return;
      }
      bytes = await p.readAsBytes();
    } else if (specificDish == null && _input.text.isEmpty) {
      return;
    }
    setState(() => _loading = true);
    try {
      final recipe = await ApiRotator.execute(context, (key) async {
        final model = GenerativeModel(model: modelName, apiKey: key);
        final prompt =
            "Strict: If input human/pet/rock/other non edible food items, reply [REJECTED]. Else: Clinical Recipe for ${specificDish ?? _input.text} given diagnosis ${widget.medicalData['diagnosis']}, avoid ${widget.medicalData['avoidList']}.";
        final res = await model.generateContent(bytes != null
            ? [
                Content.multi([TextPart(prompt), DataPart('image/jpeg', bytes)])
              ]
            : [Content.text(prompt)]);
        return res.text ?? "";
      });
      if (recipe.contains("[REJECTED]")) {
        if (mounted) {
          _showWarning();
        }
      } else {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          await FirebaseFirestore.instance
              .collection('artifacts')
              .doc(authorizedAppId)
              .collection('users')
              .doc(uid)
              .collection('history')
              .add({
            'data': recipe,
            'type': 'recipe',
            'time': FieldValue.serverTimestamp()
          });
        }
        _input.clear();
        if (mounted) {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (c) => FullScreenResult(
                      title: specificDish ?? "Medical Recipe", data: recipe)));
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _showWarning() {
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
                title: const Text("Safety Guard"),
                content: const Text("Item identified as non-edible."),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("OK"))
                ]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text("KITCHEN SUITE",
              style: GoogleFonts.playfairDisplay(fontWeight: FontWeight.bold))),
      body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("DOCTOR'S CHOICE",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color.fromARGB(255, 106, 105, 105),
                    fontSize: 10,
                    letterSpacing: 2)),
            const SizedBox(height: 16),
            Row(children: [
              _mealCard("MORNING", _cachedDailyMeals?['Morning'] ?? "Morning"),
              _mealCard("LUNCH", _cachedDailyMeals?['Lunch'] ?? "Lunch"),
              _mealCard("EVENING", _cachedDailyMeals?['Evening'] ?? "Evening")
            ]),
            const SizedBox(height: 40),
            const Text("CUSTOM RECIPE GENERATOR",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 12),
            TextField(
                controller: _input,
                maxLines: 2,
                decoration: InputDecoration(
                    hintText: "Enter food name or Enter ingredients...",
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16)),
                    fillColor: Colors.white,
                    filled: true)),
            const SizedBox(height: 16),
            _loading
                ? const Center(child: CircularProgressIndicator())
                : Row(children: [
                    Expanded(
                        child: ElevatedButton(
                            onPressed: () => _cook(),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: clinicalGreen,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12))),
                            child: const Text("GENERATE RECIPE"))),
                    const SizedBox(width: 8),
                    IconButton.filled(
                        onPressed: () => _cook(source: ImageSource.gallery),
                        icon: const Icon(Icons.collections_bookmark_rounded)),
                    const SizedBox(width: 8),
                    IconButton.filled(
                        onPressed: () => _cook(source: ImageSource.camera),
                        icon: const Icon(Icons.camera_rounded))
                  ]),
          ])),
    );
  }

  Widget _mealCard(String time, String dish) {
    return Expanded(
        child: GestureDetector(
            onTap: () => _cook(specificDish: dish),
            child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: clinicalGreen.withAlpha(30)),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 4)
                    ]),
                child: Column(children: [
                  Text(time,
                      style: const TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                          color: clinicalGreen)),
                  const SizedBox(height: 8),
                  Text(dish,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 9, fontWeight: FontWeight.bold),
                      maxLines: 2)
                ]))));
  }
}

class ForensicLab extends StatefulWidget {
  const ForensicLab({super.key});
  @override
  State<ForensicLab> createState() => _ForensicLabState();
}

class _ForensicLabState extends State<ForensicLab> {
  final _picker = ImagePicker();
  bool _loading = false;
  Future<void> _scan() async {
    final p = await _picker.pickImage(source: ImageSource.camera);
    if (p == null) {
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiRotator.execute(context, (key) async {
        final model = GenerativeModel(model: modelName, apiKey: key);
        final r = await model.generateContent([
          Content.multi([
            TextPart(
                "Safety: If human/rock/tool/other non edible food items, reply [REJECTED]. Else: Analyze food purity. Professional English."),
            DataPart('image/jpeg', await p.readAsBytes())
          ])
        ]);
        return r.text ?? "";
      });
      if (res.contains("[REJECTED]")) {
        if (mounted) {
          _showWarning();
        }
      } else {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          await FirebaseFirestore.instance
              .collection('artifacts')
              .doc(authorizedAppId)
              .collection('users')
              .doc(uid)
              .collection('history')
              .add({
            'data': res,
            'type': 'lab',
            'time': FieldValue.serverTimestamp()
          });
        }
        if (mounted) {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (c) => FullScreenResult(
                      title: "Clinical Lab Report", data: res)));
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _showWarning() {
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
                title: const Text("Scan Blocked"),
                content: const Text("Sample identified as non-food."),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("OK"))
                ]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: Center(
            child: _loading
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                        const Icon(Icons.biotech_rounded,
                            size: 100, color: clinicalGreen),
                        const Text("PURITY ANALYSIS LAB",
                            style: TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 48),
                        ElevatedButton.icon(
                            onPressed: _scan,
                            icon: const Icon(Icons.camera_rounded),
                            label: const Text("START SCAN"),
                            style: ElevatedButton.styleFrom(
                                minimumSize: const Size(220, 60)))
                      ])));
  }
}

class ProfilePage extends StatelessWidget {
  final Map<String, dynamic> medicalData;
  final User user;
  const ProfilePage({super.key, required this.medicalData, required this.user});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(title: const Text("PATIENT IDENTITY"), actions: [
        IconButton(
            onPressed: () => FirebaseAuth.instance.signOut(),
            icon: const Icon(Icons.logout, color: Colors.red))
      ]),
      body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withAlpha(5), blurRadius: 10)
                    ]),
                child: Row(children: [
                  CircleAvatar(
                      radius: 35,
                      backgroundColor: clinicalGreen.withAlpha(30),
                      child: Text(
                          user.email != null && user.email!.isNotEmpty
                              ? user.email![0].toUpperCase()
                              : "P",
                          style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: clinicalGreen))),
                  const SizedBox(width: 20),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(user.email ?? "Clinic Patient",
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                        Text("PATIENT ID: ${user.uid.substring(0, 15)}",
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey))
                      ]))
                ])),
            const SizedBox(height: 32),
            Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("CURRENT DIAGNOSIS",
                          style: TextStyle(
                              fontSize: 9,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5)),
                      Text(medicalData['diagnosis'].toString().toUpperCase(),
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: clinicalGreen)),
                      const SizedBox(height: 12),
                      Wrap(
                          spacing: 8,
                          children: (medicalData['avoidList'] as List)
                              .map((i) => Chip(
                                  label: Text(i.toString(),
                                      style: const TextStyle(fontSize: 10)),
                                  backgroundColor: Colors.red.withAlpha(15),
                                  side: BorderSide.none))
                              .toList()),
                      const SizedBox(height: 16),
                      SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (c) => const MedicalOnboarding(
                                          isUpdate: true))),
                              child: const Text("SYNC NEW REPORT")))
                    ])),
            const SizedBox(height: 32),
            const Text("ACTIVITY LOG",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1.5)),
            _HistoryList(userId: user.uid),
          ])),
    );
  }
}

class _HistoryList extends StatelessWidget {
  final String userId;
  const _HistoryList({required this.userId});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('artifacts')
          .doc(authorizedAppId)
          .collection('users')
          .doc(userId)
          .collection('history')
          .orderBy('time', descending: true)
          .limit(5)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData ||
            snapshot.data == null ||
            snapshot.data!.docs.isEmpty) {
          return const Padding(
              padding: EdgeInsets.all(12),
              child: Text("No clinic records found.",
                  style: TextStyle(color: Colors.grey, fontSize: 12)));
        }
        return Column(
            children: snapshot.data!.docs
                .map((doc) => Card(
                    elevation: 0,
                    color: Colors.white,
                    margin: const EdgeInsets.only(top: 8),
                    child: ListTile(
                        leading:
                            Icon(doc.get('type') == 'recipe' ? Icons.medical_services : Icons.biotech,
                                size: 18, color: clinicalGreen),
                        title: Text(doc.get('data').toString().split('\n').first,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                        trailing: const Icon(Icons.chevron_right, size: 14),
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (c) => FullScreenResult(
                                    title: doc.get('type') == 'recipe'
                                        ? "Medical Recipe"
                                        : "Lab Analysis",
                                    data: doc.get('data')))))))
                .toList());
      },
    );
  }
}

class FullScreenResult extends StatelessWidget {
  final String title;
  final String data;
  const FullScreenResult({super.key, required this.title, required this.data});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(title: Text(title)),
        body: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: clinicalGreen.withAlpha(20),
                      borderRadius: BorderRadius.circular(4)),
                  child: const Text("OFFICIAL CLINICAL ANALYSIS",
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                          color: clinicalGreen))),
              const SizedBox(height: 24),
              MarkdownBody(
                  data: data,
                  styleSheet: MarkdownStyleSheet(
                      h1: const TextStyle(
                          color: clinicalGreen, fontWeight: FontWeight.bold),
                      p: const TextStyle(height: 1.5, fontSize: 14)))
            ])));
  }
}
