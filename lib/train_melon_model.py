# === train_melon_model.py ===
import os
import shutil
import glob
import tempfile
import tensorflow as tf
from sklearn.model_selection import train_test_split
from tensorflow.keras.preprocessing.image import ImageDataGenerator
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import GlobalAveragePooling2D, Dense, Dropout, BatchNormalization
from tensorflow.keras.applications import MobileNetV2
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint, ReduceLROnPlateau
import firebase_admin
from firebase_admin import credentials, storage
import splitfolders

# === 1️⃣ Inisialisasi Firebase ===
cred_path = "D:\melonFILE\\uilogin-c62bc-firebase-adminsdk-lvldt-691a13321c.json"
cred = credentials.Certificate(cred_path)
firebase_admin.initialize_app(cred, {'storageBucket': 'uilogin-c62bc.appspot.com'})
bucket = storage.bucket()

# === 2️⃣ Download Dataset dari Firebase ===
def download_folder_from_firebase(prefix, local_dir):
    blobs = bucket.list_blobs(prefix=prefix)
    for blob in blobs:
        if blob.name.endswith('/'):
            continue
        local_path = os.path.join(local_dir, os.path.relpath(blob.name, prefix))
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        blob.download_to_filename(local_path)
        print(f"📥 Downloaded: {blob.name}")

dataset_dir = tempfile.mkdtemp()
print(f"\n📂 Folder dataset sementara: {dataset_dir}")

download_folder_from_firebase("Dataset", dataset_dir)
print("✅ Dataset berhasil diunduh!\n")

# === 3️⃣ Split Dataset (70/20/10) ===
split_dir = "D:/melonFILE/DatasetSplit"
train_dir = os.path.join(split_dir, "train")
val_dir = os.path.join(split_dir, "val")
test_dir = os.path.join(split_dir, "test")

splitfolders.ratio(
    "D:/melonFILE/Dataset",   # dataset asli
    output=split_dir,
    seed=42,
    ratio=(0.7, 0.2, 0.1)     # train, val, test
)


for folder in [train_dir, val_dir, test_dir]:
    os.makedirs(folder, exist_ok=True)

for class_name in os.listdir(dataset_dir):
    class_path = os.path.join(dataset_dir, class_name)
    if not os.path.isdir(class_path):
        continue

    images = glob.glob(os.path.join(class_path, "*.*"))

    train_files, temp = train_test_split(images, test_size=0.30, random_state=42)
    val_files, test_files = train_test_split(temp, test_size=0.33, random_state=42)

    for file in train_files:
        dest = os.path.join(train_dir, class_name)
        os.makedirs(dest, exist_ok=True)
        shutil.copy(file, dest)

    for file in val_files:
        dest = os.path.join(val_dir, class_name)
        os.makedirs(dest, exist_ok=True)
        shutil.copy(file, dest)

    for file in test_files:
        dest = os.path.join(test_dir, class_name)
        os.makedirs(dest, exist_ok=True)
        shutil.copy(file, dest)

print("📌 Dataset sukses dipisah → Train / Val / Test")

# === 4️⃣ Data Augmentation (Optimasi) ===
datagen = ImageDataGenerator(
    rescale=1./255,
    rotation_range=40,
    width_shift_range=0.25,
    height_shift_range=0.25,
    shear_range=0.22,
    zoom_range=0.25,
    brightness_range=[0.65, 1.35],
    horizontal_flip=True,
    vertical_flip=False,
    fill_mode='nearest'
)

train_data = datagen.flow_from_directory(train_dir, target_size=(150,150), batch_size=32, class_mode='categorical')
val_data   = datagen.flow_from_directory(val_dir,   target_size=(150,150), batch_size=32, class_mode='categorical')
test_data  = datagen.flow_from_directory(test_dir,  target_size=(150,150), batch_size=32, class_mode='categorical', shuffle=False)

print("\n📊 Kelas terdeteksi:", train_data.class_indices)

# === 5️⃣ Model Optimized MobileNetV2 ===
base_model = MobileNetV2(input_shape=(150, 150, 3), include_top=False, weights='imagenet')
base_model.trainable = False  # Freeze dulu

model = Sequential([
    base_model,
    GlobalAveragePooling2D(),
    BatchNormalization(),
    Dense(256, activation='relu'),
    Dropout(0.35),
    BatchNormalization(),
    Dense(128, activation='relu'),
    Dropout(0.35),
    Dense(train_data.num_classes, activation='softmax')
])

model.compile(optimizer=tf.keras.optimizers.Adam(learning_rate=0.0007),
              loss='categorical_crossentropy',
              metrics=['accuracy'])

# === CALLBACK ===
os.makedirs("output", exist_ok=True)
callbacks = [
    EarlyStopping(monitor='val_loss', patience=6, restore_best_weights=True),
    ReduceLROnPlateau(monitor='val_loss', factor=0.4, patience=2),
    ModelCheckpoint('output/melon_model_best.h5', monitor='val_loss', save_best_only=True)
]

# === 6️⃣ TRAINING TAHAP 1 (HEAD ONLY) ===
print("\n🚀 TRAINING PHASE 1 — Freeze Base Model")
history = model.fit(train_data, validation_data=val_data, epochs=15, callbacks=callbacks)

# === Fine Tuning Phase 2 ===
base_model.trainable = True
for layer in base_model.layers[:100]:
    layer.trainable = False

model.compile(optimizer=tf.keras.optimizers.Adam(learning_rate=0.00005),
              loss='categorical_crossentropy',
              metrics=['accuracy'])

print("\n🔥 TRAINING PHASE 2 — Fine Tuning")
history_fine = model.fit(train_data, validation_data=val_data, epochs=10, callbacks=callbacks)

# === 8️⃣ Save Model ===
model.save("output/melon_model.h5")

# === 9️⃣ Convert to TFLite ===
best_model = tf.keras.models.load_model("output/melon_model_best.h5")
converter = tf.lite.TFLiteConverter.from_keras_model(best_model)
converter.optimizations = [tf.lite.Optimize.DEFAULT]
tflite_model = converter.convert()

with open("output/model_melon.tflite", "wb") as f:
    f.write(tflite_model)

# === 🔟 Save labels ===
labels = [None] * len(train_data.class_indices)
for label, index in train_data.class_indices.items():
    labels[index] = label

with open("output/labels.txt", "w") as f:
    f.write("\n".join(labels))

print("\n📋 Urutan label:", labels)

# === 🧪 Evaluasi Test ===
loss, acc = best_model.evaluate(test_data)
print(f"\n🎯 Akurasi Testing: {acc:.4f} | Loss: {loss:.4f}")

# === 🚀 UPLOAD FIREBASE ===
from google.cloud import storage
def upload_to_firebase(local_path, bucket_path):
    client = storage.Client.from_service_account_json(cred_path)
    bucket = client.bucket("uilogin-c62bc.appspot.com")
    blob = bucket.blob(bucket_path)
    blob.upload_from_filename(local_path)
    print("🚀 Upload:", bucket_path)

upload_to_firebase("output/melon_model.h5", "models/melon_model.h5")
upload_to_firebase("output/labels.txt", "models/labels.txt")
upload_to_firebase("output/model_melon.tflite", "models/model_melon.tflite")

print("\n🎉 Semua file berhasil di-upload ke Firebase Storage!")
