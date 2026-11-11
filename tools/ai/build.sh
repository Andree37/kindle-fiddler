#!/bin/sh
# Builds noface-ai for the Kindle: llama.cpp at a fixed commit, compiled with Zig for
# 32-bit ARM (Cortex-A53, NEON), static, plus tools/ai/worker.c.
#
#   tools/ai/build.sh <work dir>      -> <work dir>/noface-ai
#
# Needs git, cmake, ninja and zig. The work dir holds the llama.cpp checkout and build.
set -eu
LLAMA_COMMIT=aa75ff3  # Tested on the Paperwhite 12th gen; newer ones may change the API
here=$(cd "$(dirname "$0")" && pwd)
work=$(mkdir -p "$1" && cd "$1" && pwd)
bin="$work/bin"
mkdir -p "$bin"

# Zig as the compiler. It takes the CPU from -mcpu, so -march from ggml is dropped.
for tool in cc c++; do
    name=$([ $tool = cc ] && echo zcc || echo zcxx)
    cat > "$bin/$name" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in -march=*) ;; *) set -- "\$@" "\$a";; esac; shift; done
exec zig $tool -target arm-linux-musleabihf -mcpu=cortex_a53 "\$@"
EOF
done
printf '#!/bin/sh\nexec zig ar "$@"\n' > "$bin/zar"
printf '#!/bin/sh\nexec zig ranlib "$@"\n' > "$bin/zranlib"
chmod +x "$bin"/*

if [ ! -d "$work/llama.cpp" ]; then
    git clone -q https://github.com/ggml-org/llama.cpp.git "$work/llama.cpp"
fi
cd "$work/llama.cpp"
git fetch -q --depth 1 origin "$LLAMA_COMMIT" 2>/dev/null || true
git checkout -q "$LLAMA_COMMIT"

# ggml defines a NEON instruction 32-bit ARMv7 lacks; ARMv8 in 32-bit mode has it, and
# defining it twice fails, so skip ggml's copy there.
impl=ggml/src/ggml-cpu/ggml-cpu-impl.h
grep -q "__ARM_ARCH < 8" "$impl" || python3 - "$impl" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
a = 'inline static int32x4_t vcvtnq_s32_f32(float32x4_t v) {'
i = s.index(a)
j = s.index('\n}\n', i) + 3
open(p, 'w').write(s[:i] + '#if __ARM_ARCH < 8 // ARMv8 in 32-bit mode has this\n' + s[i:j] + '#endif\n' + s[j:])
EOF

cmake -S . -B build-kindle -G Ninja \
    -DCMAKE_C_COMPILER="$bin/zcc" -DCMAKE_CXX_COMPILER="$bin/zcxx" \
    -DCMAKE_AR="$bin/zar" -DCMAKE_RANLIB="$bin/zranlib" \
    -DCMAKE_C_COMPILER_AR="$bin/zar" -DCMAKE_CXX_COMPILER_AR="$bin/zar" \
    -DCMAKE_C_COMPILER_RANLIB="$bin/zranlib" -DCMAKE_CXX_COMPILER_RANLIB="$bin/zranlib" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=armv7l -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DLLAMA_CURL=OFF \
    -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TESTS=OFF > /dev/null
ninja -C build-kindle llama ggml > /dev/null

"$bin/zcc" -O2 -c -I include -I ggml/include "$here/worker.c" -o "$work/worker.o"
"$bin/zcxx" -static -s "$work/worker.o" \
    build-kindle/src/libllama.a build-kindle/ggml/src/libggml.a \
    build-kindle/ggml/src/libggml-cpu.a build-kindle/ggml/src/libggml-base.a \
    -o "$work/noface-ai"
echo "built $work/noface-ai"
