#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
revision=fae77ff7232cc79eecaebeb9e6839acf568d09c2

git clone --quiet --depth 1 --branch v7.7.0 https://github.com/opendocument-app/OpenDocument.core.git "$work/source"
cd "$work/source"
test "$(git rev-parse HEAD)" = "$revision"
git apply "$repo/tools/odr/7.7.0.patch"

curl --fail --location --silent --show-error \
    https://github.com/opendocument-app/OpenDocument.core/releases/download/v7.7.0/odr-formula-v7.7.0.js \
    --output "$work/odr-formula.js"
printf '%s  %s\n' c6a7ee822a47b131027fcf16f33e074cbfd6117d2fc7734f1a884cbcfee85804 "$work/odr-formula.js" | shasum -a 256 -c

export CONAN_HOME="$work/conan"
conan config install .github/config/conan
# Avoid a ccache dependency in the generated Emscripten toolchain.
profile="$CONAN_HOME/profiles/emscripten-wasm"
awk '!/^tools.cmake.cmaketoolchain:extra_variables=/' "$profile" > "$work/wasm-profile"
mv "$work/wasm-profile" "$profile"

if [[ -n "${ODR_BUILD_PROFILE:-}" ]]; then
    build_profile=$ODR_BUILD_PROFILE
else
    conan profile detect
    build_profile=default
fi
conan install . --output-folder "$work/build" --profile:host emscripten-wasm \
    --profile:build "$build_profile" --lockfile-partial --build missing -o '&:with_wasm=True'

source "$work/build/conanbuild.sh"
cmake -S . -B "$work/build" -G Ninja -DCMAKE_TOOLCHAIN_FILE=conan_toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DODR_WASM=ON -DODR_CLI=OFF \
    -DODR_WITH_HTTP_SERVER=OFF -DODR_TEST=OFF -DGIT_HEAD_SHA1="$revision" \
    -DODR_FORMULA_MODULE="$work/odr-formula.js"
cmake --build "$work/build" --target odr_wasm

dist="$work/build/wasm/dist"
vendor="$repo/assets/js/vendor"
cp "$dist/index.js" "$vendor/odr-7.7.0.mjs"
cp "$dist/odr-core.mjs" "$dist/odr-core.wasm" "$vendor/"
