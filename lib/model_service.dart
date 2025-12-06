import 'package:tflite_flutter/tflite_flutter.dart';

class ModelService {
  late Interpreter interpreter;

  Future<void> loadModel() async {
    interpreter = await Interpreter.fromAsset('assets/model/best_float16.tflite');
    print("Model loaded!");
  }

  List<double> predict(List<double> input) {
    var inputTensor = [input];
    var outputTensor = List.filled(6, 0).reshape([1, 6]); // sesuaikan jumlah class

    interpreter.run(inputTensor, outputTensor);
    return outputTensor[0].cast<double>();
  }
}
