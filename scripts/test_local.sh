#!/usr/bin/env bash
# One-command local build + test:
#   bash scripts/test_local.sh
#
# Configures (first run), builds picoquic_vendor_test + picoquic_fanout_server,
# runs the vendor smoke test, then the aioquic end-to-end fanout test against a
# live server. Works on Windows (git-bash, clang-cl via Ninja) and Linux.
#
# Environment overrides:
#   BUILD_DIR    build directory            (default: build_local)
#   VCPKG_ROOT   Windows only: vcpkg checkout providing the deps
#                (default: $USERPROFILE/vcpkg-local)
#   VCVARS       Windows only: path to vcvars64.bat
#                (default: VS2026 Community)
set -euo pipefail

cd "$(dirname "$0")/.."
repo="$(pwd)"
BUILD_DIR="${BUILD_DIR:-build_local}"

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
	windows=1
	;;
*)
	windows=0
	;;
esac

if [[ $windows == 1 ]]; then
	VCPKG_ROOT="${VCPKG_ROOT:-$(cygpath -m "$USERPROFILE")/vcpkg-local}"
	VCVARS="${VCVARS:-C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\VC\\Auxiliary\\Build\\vcvars64.bat}"
	[[ -f "$(cygpath -u "$VCVARS")" ]] || { echo "vcvars64.bat not found at: $VCVARS (set VCVARS)"; exit 1; }
	[[ -d "$(cygpath -u "$VCPKG_ROOT")" ]] || { echo "vcpkg not found at: $VCPKG_ROOT (set VCPKG_ROOT)"; exit 1; }

	clang_cl=""
	for cand in "$(command -v clang-cl || true)" \
	            "$HOME/scoop/apps/llvm/current/bin/clang-cl.exe" \
	            "/c/Program Files/LLVM/bin/clang-cl.exe"; do
		if [[ -n "$cand" && -f "$cand" ]]; then
			clang_cl="$cand"
			break
		fi
	done
	[[ -n "$clang_cl" ]] || { echo "clang-cl not found (install LLVM, e.g. 'scoop install llvm')"; exit 1; }
	clang_cl="$(cygpath -m "$clang_cl")"

	# clang-cl + lld-link need the MSVC/SDK environment; source it in cmd and
	# run configure+build inside that shell.
	bat="$(mktemp --suffix=.bat)"
	cat > "$bat" << EOF
@echo off
call "$VCVARS" || exit /b 1
cd /d "$(cygpath -w "$repo")"
cmake -S flow-toolchain -B "$BUILD_DIR" -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER="$clang_cl" ^
  -DCMAKE_CXX_COMPILER="$clang_cl" ^
  -DCMAKE_LINKER="${clang_cl%clang-cl.exe}lld-link.exe" ^
  -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake ^
  -DVCPKG_TARGET_TRIPLET=x64-windows ^
  -DVCPKG_INSTALLED_DIR=flow-toolchain/vcpkg_installed || exit /b 1
cmake --build "$BUILD_DIR" --target picoquic_vendor_test picoquic_fanout_server || exit /b 1
EOF
	cmd //c "$(cygpath -w "$bat")"
	rm -f "$bat"

	# The server links Lean's shared runtime; elan resolves the toolchain from
	# fanout-core's lean-toolchain pin.
	lean_prefix="$(cd flow-toolchain/fanout-core && lean --print-prefix)"
	export PATH="$(cygpath -u "$lean_prefix")/bin:$(cygpath -u "$VCPKG_ROOT")/installed/x64-windows/bin:$repo/flow-toolchain/vcpkg_installed/x64-windows/bin:$PATH"
	server_exe="$repo/$BUILD_DIR/picoquic_fanout_server.exe"
	vendor_exe="$repo/$BUILD_DIR/picoquic_vendor_test.exe"
else
	cmake -S flow-toolchain -B "$BUILD_DIR" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON
	cmake --build "$BUILD_DIR" --target picoquic_vendor_test picoquic_fanout_server
	server_exe="$repo/$BUILD_DIR/picoquic_fanout_server"
	vendor_exe="$repo/$BUILD_DIR/picoquic_vendor_test"
fi

echo "=== picoquic_vendor_test ==="
"$vendor_exe"

echo "=== end-to-end fanout test ==="
cd flow-toolchain
"$server_exe" 4433 > /dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -f "$repo"/flow-toolchain/fanout_server.*.xml' EXIT
sleep 2
kill -0 "$server_pid" 2>/dev/null || { echo "server failed to start"; exit 1; }
cd examples
pixi run python test_picoquic_fanout.py --port 4433
echo "=== ALL LOCAL TESTS PASSED ==="
