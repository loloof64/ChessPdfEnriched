# Chess PDF Enriched

Read your chess pdf files with moves interactivity.

## For developers

### TfLite model

1. Upload the Google Colab notebook (`train_chess_classifier.ipynb`) to your account
2. Run the Colab (with GPU)
3. Download the generated model and save it as **`assets/models/chess_pieces.tflite`**

### TFLite native library (required for board detection)

The `tflite_flutter` plugin requires a platform-native shared library that **must be built locally** — it is not committed to the repository because:

- On Linux, the `.so` is linked against glibc and must match your distro's version
- On Windows, the `.dll` depends on your MSVC/runtime version
- On macOS, see the [tflite_flutter macOS instructions](https://pub.dev/packages/tflite_flutter)

The built file must be placed in a `blobs/` folder at the project root, and also copied into the debug bundle for `flutter run`.

---

#### Linux

**Prerequisites:** `git`, `cmake`, `gcc` (g++ 11+)

```bash
# 1. Shallow-clone only the TFLite portion of TensorFlow
mkdir /tmp/tf_src && cd /tmp/tf_src
git init
git remote add origin https://github.com/tensorflow/tensorflow.git
git sparse-checkout init --cone
git sparse-checkout set tensorflow/lite third_party tensorflow/core/public tensorflow/core/example tensorflow/tsl tensorflow/compiler
git fetch --depth=1 origin v2.18.0
git checkout FETCH_HEAD

# 2. Configure and build the TFLite C shared library (~10 min on 4 cores)
mkdir /tmp/tflite_out && cd /tmp/tflite_out
cmake /tmp/tf_src/tensorflow/lite/c \
  -DTFLITE_C_BUILD_SHARED_LIBS=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DTFLITE_ENABLE_XNNPACK=ON \
  -DCMAKE_CXX_FLAGS="-Wno-error=deprecated-declarations"
make tensorflowlite_c -j$(nproc)

# 3. Copy into the project
mkdir -p /path/to/project/blobs
cp /tmp/tflite_out/libtensorflowlite_c.so \
   /path/to/project/blobs/libtensorflowlite_c-linux.so

# 4. Also copy for flutter run (debug)
mkdir -p /path/to/project/build/linux/x64/debug/bundle/blobs
cp /tmp/tflite_out/libtensorflowlite_c.so \
   /path/to/project/build/linux/x64/debug/bundle/blobs/libtensorflowlite_c-linux.so
```

Release and profile builds pick it up automatically via `linux/CMakeLists.txt`.

---

#### Windows

**Prerequisites:** Visual Studio 2019+ (with C++ workload), `cmake`, `git`

```bat
:: 1. Shallow-clone only the TFLite portion of TensorFlow
mkdir C:\tmp\tf_src && cd C:\tmp\tf_src
git init
git remote add origin https://github.com/tensorflow/tensorflow.git
git sparse-checkout init --cone
git sparse-checkout set tensorflow/lite third_party tensorflow/core/public tensorflow/core/example tensorflow/tsl tensorflow/compiler
git fetch --depth=1 origin v2.18.0
git checkout FETCH_HEAD

:: 2. Configure and build
mkdir C:\tmp\tflite_out && cd C:\tmp\tflite_out
cmake C:\tmp\tf_src\tensorflow\lite\c ^
  -DTFLITE_C_BUILD_SHARED_LIBS=ON ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DTFLITE_ENABLE_XNNPACK=ON
cmake --build . --config Release --target tensorflowlite_c -j4

:: 3. Copy into the project
mkdir C:\path\to\project\blobs
copy C:\tmp\tflite_out\Release\tensorflowlite_c.dll ^
     C:\path\to\project\blobs\libtensorflowlite_c-win.dll

:: 4. Also copy for flutter run (debug)
mkdir C:\path\to\project\build\windows\x64\runner\Debug\blobs
copy C:\tmp\tflite_out\Release\tensorflowlite_c.dll ^
     C:\path\to\project\build\windows\x64\runner\Debug\blobs\libtensorflowlite_c-win.dll
```

> **Note:** The Windows `CMakeLists.txt` equivalent of the Linux install snippet is:
>
> ```cmake
> install(
>   FILES "${PROJECT_BUILD_DIR}/../blobs/libtensorflowlite_c-win.dll"
>   DESTINATION "${CMAKE_INSTALL_PREFIX}/blobs/"
>   COMPONENT Runtime
> )
> ```
>
> Add this to `windows/CMakeLists.txt` if you need release builds to bundle it.

### Figurine/text mapping model

1. Import the **train_figurine_classifier.ipynb** and **train_text_classifier.ipynb** into your Google Colab, and execute all cells (don't forget adapt the pdf book)
2. Download the produced models in folder **assets**
