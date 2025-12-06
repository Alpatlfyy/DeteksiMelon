import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class TFLiteService {
  Interpreter? _interpreter;
  late List<String> labels;

  static final TFLiteService _instance = TFLiteService._internal();
  factory TFLiteService() => _instance;
  TFLiteService._internal();

  // ========================================================================
  // LOAD MODEL
  // ========================================================================
  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/model/best_float16.tflite',
        options: InterpreterOptions()..threads = 2,
      );

      labels = await rootBundle
          .loadString('assets/model/labels.txt')
          .then((value) => value.split('\n').where((e) => e.trim().isNotEmpty).toList());

      print("✅ TFLite berhasil di-load! Jumlah label: ${labels.length}");
    } catch (e) {
      print("❌ Gagal load TFLite: $e");
      rethrow;
    }
  }

  // ========================================================================
  // PREPROCESS: File → Float32List (1,224,224,3)
  // ========================================================================
  Future<Float32List> _preprocess(File imageFile) async {
    final imgBytes = await imageFile.readAsBytes();
    img.Image? oriImage = img.decodeImage(imgBytes);

    if (oriImage == null) {
      throw Exception("Gambar tidak dapat dibuka/dikonversi.");
    }

    final resized = img.copyResize(oriImage, width: 224, height: 224);

    // YOLOv8-Classification TFLite: input shape [1,224,224,3]
    final Float32List inputBuffer = Float32List(224 * 224 * 3);
    int index = 0;

    for (int y = 0; y < 224; y++) {
      for (int x = 0; x < 224; x++) {
        final pixel = resized.getPixel(x, y);

        inputBuffer[index++] = pixel.r / 255.0;
        inputBuffer[index++] = pixel.g / 255.0;
        inputBuffer[index++] = pixel.b / 255.0;
      }
    }

    return inputBuffer;
  }

  // ========================================================================
  // SOFTMAX
  // ========================================================================
  List<double> _softmax(List<double> logits) {
    double maxLogit = logits.reduce(max);
    List<double> expVals = logits.map((e) => exp(e - maxLogit)).toList();
    double sum = expVals.reduce((a, b) => a + b);
    return expVals.map((e) => e / sum).toList();
  }

  // ========================================================================
  // PREDICT
  // ========================================================================
  Future<Map<String, dynamic>> predict(File imageFile) async {
    if (_interpreter == null) {
      await loadModel();
    }

    final input = await _preprocess(imageFile);

    // OUTPUT shape: [1, num_classes]
    final output = List.filled(labels.length, 0.0).reshape([1, labels.length]);

    _interpreter!.run(input.reshape([1, 224, 224, 3]), output);

    final List<double> logits = output[0].cast<double>();
    final probs = _softmax(logits);

    // Ambil label paling tinggi
    int maxIndex = 0;
    double maxValue = probs[0];

    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > maxValue) {
        maxValue = probs[i];
        maxIndex = i;
      }
    }

    return {
      "label": labels[maxIndex],
      "confidence": maxValue,
      "raw_probabilities": probs,
    };
  }

  // ========================================================================
  // DISPOSE
  // ========================================================================
  void dispose() {
    try {
      _interpreter?.close();
      print("🧹 Interpreter TFLite dibersihkan.");
    } catch (e) {
      print("⚠ Error saat dispose: $e");
    } finally {
      _interpreter = null;
    }
  }
}
