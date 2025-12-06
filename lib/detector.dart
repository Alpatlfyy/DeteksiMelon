// detector_page.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'hasil_page.dart';



// Import service TFLite yang baru dibuat
import 'tflite_service.dart';
import 'hasil_page.dart'; // Import HasilPage

// --- PENTING: GANTI DENGAN API KEY ANDA ---
const apiKey = "AIzaSyDhmVv9E88sPBeYB3mem28yUPVg_EnrDHw"; // GANTI DENGAN API KEY ANDA

// Asumsi: cameras diinisialisasi di main/sebelum navigasi
late List<CameraDescription> cameras;

class DetectorPage extends StatefulWidget {
  const DetectorPage({super.key});

  @override
  State<DetectorPage> createState() => _DetectorPageState();
}

class _DetectorPageState extends State<DetectorPage> with WidgetsBindingObserver {
  File? _image; // Gambar yang sedang dipratinjau
  final ImagePicker _picker = ImagePicker();

  // Camera & Gemini State
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isAnalyzing = false; // Status untuk loading saat AI bekerja
  final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: apiKey);

  // --- TFLite State ---
  late TFLiteService _tfliteService;
  bool _isTfliteInitialized = false;
  // --------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeFirebase(); // 🔹 Tambahkan ini
    _initializeCamera();
    _initializeTFLite();
  }

  Future<void> _initializeFirebase() async {
    try {
      await Firebase.initializeApp();
      print("✅ Firebase berhasil diinisialisasi");
    } catch (e) {
      print("❌ Gagal inisialisasi Firebase: $e");
    }
  }

  Future<void> _initializeTFLite() async {
    _tfliteService = TFLiteService();
    try {
      await _tfliteService.loadModel();
      if (mounted) {
        setState(() => _isTfliteInitialized = true);
      }
    } catch (e) {
      print("Error inisialisasi TFLite: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Error TFLite: Gagal memuat model.")),
        );
      }
    }
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
      _tfliteService.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
      _initializeTFLite();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _tfliteService.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    try {
      cameras = await availableCameras();
      final CameraDescription backCamera = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });
    } on CameraException catch (e) {
      print("Camera Error: $e");
      setState(() {
        _isCameraInitialized = false;
      });
    }
  }

  // Tambahkan fungsi ini di _DetectorPageState
  String _cleanResultText(String rawText) {
    String cleaned = rawText;

    // 1️⃣ Hapus semua heading Markdown, misal ##, ###, #### di awal baris
    cleaned = cleaned.replaceAll(RegExp(r'^\s*#{1,6}\s*', multiLine: true), '');

    // 2️⃣ Hapus semua bold atau italic Markdown **, __, *, _
    cleaned = cleaned.replaceAll(RegExp(r'(\*\*|__|\*|_)'), '');

    // 3️⃣ Hapus strikethrough ~~
    cleaned = cleaned.replaceAll('~~', '');

    // 4️⃣ Bersihkan baris kosong berlebih
    cleaned = cleaned.replaceAll(RegExp(r'\n{2,}'), '\n');

    // 5️⃣ Trim spasi di awal/akhir
    cleaned = cleaned.trim();

    return cleaned;
  }



  Future<void> _performDetectionGemini() async {
    if (_image == null || _isAnalyzing) return;

    setState(() {
      _isAnalyzing = true;
    });

    try {
      const String prompt = """
Sebagai ahli botani, analisis gambar daun melon ini.
Berikan respons dalam format Markdown yang rapi dan jelas. Gunakan emoji di setiap judul.
Jika gambar tidak jelas, bukan daun, atau sehat, beritahu dengan sopan.
Jika ada penyakit, ikuti format ini dengan ketat:

**🌿 Nama Penyakit**
*Nama ilmiah penyakit (jika relevan)*

**📋 Gejala Utama**
- Jelaskan gejala visual yang paling umum secara poin.
- Tambahkan poin gejala lain jika ada.

**🔬 Penyebab & Pemicu**
Jelaskan secara singkat apa yang menyebabkan penyakit ini (misalnya jamur, bakteri, atau kondisi lingkungan).

**💊 Rekomendasi Penanganan**
1.  **Langkah Awal:** Berikan langkah pertama yang paling penting dan mudah dilakukan.
2.  **Perawatan Lanjutan:** Jelaskan metode perawatan lebih lanjut (misalnya penggunaan fungisida/pestisida spesifik).
3.  **Metode Organik:** Berikan alternatif penanganan organik jika memungkinkan.

**🛡️ Tindakan Pencegahan**
1.  **Pencegahan 1:** Berikan tips pencegahan yang paling efektif.
2.  **Pencegahan 2:** Tambahkan tips lain.

---
*Disclaimer: Analisis ini dihasilkan oleh AI sebagai panduan awal. Konsultasikan dengan ahli pertanian untuk diagnosis pasti.*
""";

      final Uint8List bytes = await _image!.readAsBytes();
      final String mimeType = _image!.path.endsWith('.png') ? 'image/png' : 'image/jpeg';

      final content = Content.multi([
        TextPart(prompt),
        DataPart(mimeType, bytes),
      ]);

      final response = await model.generateContent([content]);
      final geminiResultText = response.text ?? "Maaf, diagnosis gagal mendapatkan respons.";

      // Bersihkan Markdown
      final cleanedResult = _cleanResultText(geminiResultText);

      // Simpan ke Realtime Database
      await _saveDetectionToRealtimeDB(
        method: "Gemini",
        label: cleanedResult,
        confidence: 1.0,
      );

      if (mounted) {
        // Tampilkan hasil bersih
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => HasilPage(
              result: DetectionResult(
                rawGeminiOutput: geminiResultText,
                method: "Gemini",
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error Deteksi AI Gemini: $e")),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _image = null;
        });
      }
    }
  }

  Future<void> _performDetectionCNN() async {
    if (_image == null || _isAnalyzing || !_isTfliteInitialized) return;

    setState(() => _isAnalyzing = true);

    try {
      // 🔥 Panggil TFLiteService versi kamu
      final result = await _tfliteService.predict(_image!);

      final String label = result["label"];
      final double confidence = result["confidence"];

      final String formattedCnnOutput = """
⚡ Hasil Deteksi CNN (Offline)

📌 Identifikasi: $label
🎯 Confidence: ${(confidence * 100).toStringAsFixed(2)} %

Catatan:
- Model menggunakan YOLOv8-Classification (TFLite).
""";

      // 🔥 Simpan ke database
      await _saveDetectionToRealtimeDB(
        method: "CNN",
        label: label,
        confidence: confidence,
      );

      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => HasilPage(
              result: DetectionResult(
                rawGeminiOutput: formattedCnnOutput,
                method: "CNN",
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error Deteksi CNN: $e")),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _image = null;
        });
      }
    }
  }

  // 🔹 Tambahan baru: Simpan hasil ke Realtime Database
  Future<void> _saveDetectionToRealtimeDB({
    required String method,
    required String label,
    required double confidence,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print("⚠️ Tidak ada user yang login, data tidak disimpan");
        return;
      }

      final DatabaseReference dbRef = FirebaseDatabase.instance
          .ref("users/${user.uid}/detections")
          .push();

      // Simpan versi ringkas (label) dan versi lengkap (fullText)
      await dbRef.set({
        'method': method,
        'label': label.length > 100 ? label.substring(0, 100) + '...' : label, // ringkas untuk list
        'fullText': label, // simpan seluruh teks lengkap
        'confidence': confidence,
        'timestamp': DateTime.now().toIso8601String(),
      });

      print("✅ Hasil deteksi tersimpan lengkap di Realtime Database milik user: ${user.uid}");
    } catch (e) {
      print("❌ Gagal menyimpan ke Realtime Database: $e");
    }
  }


  Future<void> _takePhoto() async {
    if (!_isCameraInitialized || _cameraController == null || _cameraController!.value.isTakingPicture || _isAnalyzing) {
      return;
    }
    try {
      final XFile imageFile = await _cameraController!.takePicture();
      setState(() {
        _image = File(imageFile.path);
      });
    } catch (e) {
      print(e);
    }
  }

  Future<void> _pickFromGallery() async {
    if (_isAnalyzing) return;
    final pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color primaryColor = Color(0xFF064E3B);
    final w = MediaQuery.of(context).size.width;
    final circleSize = w * 0.55;

    if (_isAnalyzing) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: primaryColor,
          // Teks UI: Sudah Bahasa Indonesia
          title: const Text("Detektor Daun Melon", style: TextStyle(color: Colors.white)),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: primaryColor),
              SizedBox(height: 16),
              // Teks UI: Sudah Bahasa Indonesia
              Text("Menganalisis gambar...", style: TextStyle(fontSize: 16, color: primaryColor)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primaryColor,
        // Teks UI: Sudah Bahasa Indonesia
        title: const Text(
          "Detektor Daun Melon",
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 12),
            // Teks UI: Sudah Bahasa Indonesia
            Text(
              "Deteksi penyakit daun melon secara cepat dengan AI.",
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[700],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Stack(
              alignment: Alignment.center,
              children: [
                if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized)
                  ClipOval(
                    child: SizedBox(
                      width: circleSize,
                      height: circleSize,
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: circleSize,
                          height: _cameraController!.value.aspectRatio != 0
                              ? circleSize / _cameraController!.value.aspectRatio
                              : circleSize, // fallback aman kalau aspectRatio 0
                          child: CameraPreview(_cameraController!),
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    width: circleSize,
                    height: circleSize,
                    decoration: const BoxDecoration(
                      color: Colors.black87,
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Icon(Icons.camera_alt_rounded, size: 42, color: Colors.white),
                    ),
                  ),
                GestureDetector(
                  onTap: _takePhoto,
                  child: Container(
                    width: circleSize,
                    height: circleSize,
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.4),
                      shape: BoxShape.circle,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.camera_alt_outlined, size: 48, color: Colors.white),
                        SizedBox(height: 8),
                        Text(
                          "Ambil Gambar",
                          style: TextStyle(
                              color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: w * 0.7,
              child: OutlinedButton.icon(
                onPressed: _pickFromGallery,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: primaryColor),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.image, color: primaryColor),
                // Teks UI: Sudah Bahasa Indonesia
                label: const Text(
                  "Unggah Dari Galeri",
                  style: TextStyle(color: primaryColor, fontSize: 15),
                ),
              ),
            ),
            const SizedBox(height: 28),
            if (_image != null) ...[
              // Teks UI: Sudah Bahasa Indonesia
              const Text(
                "Gambar Terpilih:",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  _image!,
                  width: w * 0.8,
                  height: w * 0.8,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: w * 0.7,
                child: ElevatedButton.icon(
                  onPressed: _performDetectionGemini,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.psychology, color: Colors.white),
                  // Teks UI: Sudah Bahasa Indonesia
                  label: const Text(
                    "DETEKSI GEMINI (ONLINE)",
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (_isTfliteInitialized)
                SizedBox(
                  width: w * 0.7,
                  child: OutlinedButton.icon(
                    onPressed: _performDetectionCNN,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.deepOrange),
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.speed_rounded, color: Colors.deepOrange),
                    // Teks UI: Sudah Bahasa Indonesia
                    label: const Text(
                      "KLASIFIKASI CNN (OFFLINE)",
                      style: TextStyle(color: Colors.deepOrange, fontSize: 14),
                    ),
                  ),
                )
              else
              // Teks UI: Sudah Bahasa Indonesia
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text("Model offline sedang dimuat...", style: TextStyle(color: Colors.grey)),
                ),
              const SizedBox(height: 28),
            ],
            // Teks UI: Sudah Bahasa Indonesia
            _buildSectionTitle("Fitur Utama", primaryColor),
            const SizedBox(height: 8),
            // Teks UI: Sudah Bahasa Indonesia
            _featureCard(Icons.auto_awesome, "Analisis Detail AI", "Dapatkan penjelasan lengkap dari Gemini AI."),
            _featureCard(Icons.healing, "Saran Perawatan", "Solusi dan tips pencegahan penyakit."),
            _featureCard(Icons.wifi_off, "Mode Offline Cepat", "Klasifikasi instan tanpa koneksi internet."),
            const SizedBox(height: 20),
            // Teks UI: Sudah Bahasa Indonesia
            _buildSectionTitle("Tips Akurasi", primaryColor),
            const SizedBox(height: 8),
            // Teks UI: Sudah Bahasa Indonesia
            const Text(
              "Pastikan gambar daun fokus, mendapat cahaya yang cukup, dan tidak blur untuk hasil deteksi terbaik.",
              style: TextStyle(fontSize: 14, color: Colors.black54),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, Color color) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  Widget _featureCard(IconData icon, String title, String subtitle) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF064E3B).withOpacity(0.1),
          child: Icon(icon, color: const Color(0xFF064E3B)),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}