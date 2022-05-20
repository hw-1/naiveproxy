#!/bin/sh

. ./get-sysroot.sh

case "$ARCH" in
  Linux)
    WITH_GOOS=linux
    if [ "$target_os" = 'android' ]; then
      WITH_GOOS=android
    fi
    case "$target_cpu" in
      x64) WITH_GOARCH=amd64;;
      x86) WITH_GOARCH=386;;
      arm64) WITH_GOARCH=arm64;;
      arm) WITH_GOARCH=arm;;
      mipsel) WITH_GOARCH=mipsle;;
      mips64el) WITH_GOARCH=mips64le;;
    esac
    shared_lib_name='libcronet.so'
    static_lib_name='libcronet_static.a'
  ;;
  Windows)
    WITH_GOOS=windows
    case "$target_cpu" in
      x64) WITH_GOARCH=amd64;;
      x86) WITH_GOARCH=386;;
      arm64) WITH_GOARCH=arm64;;
    esac
    shared_lib_name='cronet.dll.lib'
    dll_name='cronet.dll'
    static_lib_name='cronet_static.lib'
  ;;
  Darwin)
    WITH_GOOS=darwin
    case "$target_cpu" in
      x64) WITH_GOARCH=amd64;;
      arm64) WITH_GOARCH=arm64;;
    esac
    shared_lib_name='libcronet.dylib'
    static_lib_name='libcronet_static.a'
  ;;
esac

set -ex

mkdir -p out/Release/cronet

getflag() {
  local ninjafile=./out/Release/obj/components/cronet/$1.ninja
  local flagname="$2"
  grep "\<$flagname = " $ninjafile | cut -d= -f2- | sed 's/\$:/:/g;s/\\%/%/g;s/\\\$\$/\$/g' | sed "s#=\.\./#=$PWD/out/Release/../#g"
}

if [ "$target_os" = 'android' ]; then
  WITH_SYSROOT='third_party/android_ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot'
fi

# Extracts this manually because the sysroot flag generated by Chromium is bundled with other irrelevant stuff.
if [ "$WITH_SYSROOT" ]; then
  sysroot_flag='--sysroot=./sysroot'
fi

# Mac SDK path should be detected in the CGO builder.
if [ "$ARCH" = 'Darwin' ]; then
  sysroot_flag='-isysroot ./sysroot'
fi

cp -a out/Release/$shared_lib_name out/Release/cronet/
if [ "$ARCH" = 'Windows' ]; then
  cp -a out/Release/$dll_name out/Release/cronet/
fi
cp -a out/Release/obj/components/cronet/$static_lib_name out/Release/cronet/
cp -a components/cronet/native/sample/cronet_example.go out/Release/cronet/
cp -a components/cronet/native/generated/cronet.idl_c.h out/Release/cronet/
cp -a components/cronet/native/include/cronet_c.h out/Release/cronet/
cp -a components/cronet/native/include/cronet_export.h out/Release/cronet/
cp -a components/grpc_support/include/bidirectional_stream_c.h out/Release/cronet/
if [ "$WITH_SYSROOT" ]; then
  cp -a "$PWD/$WITH_SYSROOT" out/Release/cronet/sysroot
fi
if [ "$target_os" = 'android' ]; then
  # Included by base/BUILD.gn
  cp -a base/android/library_loader/anchor_functions.lds out/Release/cronet
fi
cp -a components/cronet/native/go-build.sh out/Release/cronet/

# CGO's intermediate C files are very small. They need no optimization and only very basic flags.
getcgoflags() {
  # -mllvm: avoid confusion with -m*; we don't use this flag in cgo flags anyway.
  # ' -march= ': artifact during OpenWrt build
  # -arch xyz: Mac specific
  # -fmsc-version=: Windows specific
  # -Wl,--dynamic-linker=: OpenWrt specific
  # --unwindlib=: Android specific
  sed 's/-mllvm[ :][^ ]*//g;s/ -march= / /g' | grep -Eo ' (-fuse-ld=|--target=|-m|-arch |-fmsc-version=|-Wl,--dynamic-linker=|--unwindlib=)[^ ]*' | tr -d '\n'
}

cgo_cflags="$(getflag cronet_example_external cflags | getcgoflags) $sysroot_flag"
cgo_ldflags="$(getflag cronet_example_external ldflags | getcgoflags) $sysroot_flag"
# sysroot: It helps cronet_example_external compile, but CGO uses manually constructed sysroot option.
# NATVIS: Windows specific; cannot be turned off cleanly with GN flags, so removes it manually here.
shared_ldflags="$(getflag cronet_example_external ldflags | sed 's/-isysroot [^ ]*//g;s#/NATVIS:[^ ]*##g') $sysroot_flag"
static_ldflags="$(getflag cronet_example_external_static ldflags | sed 's/-isysroot [^ ]*//g;s#/NATVIS:[^ ]*##g') $sysroot_flag"
shared_solibs="$(getflag cronet_example_external solibs)"
static_solibs="$(getflag cronet_example_external_static solibs)"
shared_libs="$(getflag cronet_example_external libs)"
static_libs="$(getflag cronet_example_external_static libs)"
shared_frameworks="$(getflag cronet_example_external frameworks)"
static_frameworks="$(getflag cronet_example_external_static frameworks)"

if [ "$ARCH" = 'Linux' ]; then
  static_libs="./$static_lib_name $static_libs"
  # Regular Linux seems to require this.
  if [ ! "$target_os" ]; then
    static_libs="$static_libs -lm"
  fi
  if [ "$target_os" = 'android' ]; then
    static_libs="$(echo $static_libs | sed 's#[^ ]*/anchor_functions.lds#./anchor_functions.lds#')"
  fi
elif [ "$ARCH" = 'Windows' ]; then
  # -Wno-dll-attribute-on-redeclaration: https://github.com/golang/go/issues/46502
  cgo_cflags="$cgo_cflags -Wno-dll-attribute-on-redeclaration"

  # Chromium uses clang-cl.exe, but CGO officially only supports GCC/MinGW on Windows. See https://github.com/golang/go/issues/17014.
  # 1. CGO hardcodes GCC options incompatible with clang-cl, so an extra clang.exe is required (Chromium only provides clang-cl.exe).
  # 2. We need CGO to link LLVM bitcode from Chromium, so ld cannot work and lld is required.
  # 3. CGO passes GCC options incompatible with lld, so an extra lld wrapper is required to remove those options.
  # 4. I didn't figure out a way to make the whole pipeline use lld-link-wrapper cleanly:
  #   * `-fuse-ld=lld --ld-path=lld-link-wrapper` reports `--ld-path` is an unknown argument.
  #   * `-fuse-ld=.../lld-link-wrapper.exe` creates garbled linker path.
  #   So uses a hack to rename lld-link.exe to lld-link-old.exe which is called from the wrapper "lld-link.exe".
  # 5. lld-13 does not work with bitcode produced by Chromium's lld-15.
  #    So copies clang-13 from environment to Chromium's LLVM bin directory, and uses clang-13 together with lld-15.
  cgo_ldflags="-fuse-ld=lld $cgo_ldflags"

  # Helps clang find architecture-specific libpath.
  # Chromium uses setup_toolchain.py to create -libpath flags. It's too complicated.
  # This option is already in cflags.
  if [ "$target_cpu" = 'arm64' ]; then
    cgo_ldflags="$cgo_ldflags --target=arm64-windows"
  fi

  # Hardcodes sys_lib_flags values from build/toolchain/win/BUILD.gn instead of extracting it from GN artifacts.
  case "$target_cpu" in
    x64) cgo_ldflags="$cgo_ldflags -Wl,/MACHINE:X64";;
    x86) cgo_ldflags="$cgo_ldflags -Wl,/MACHINE:X86";;
    arm64) cgo_ldflags="$cgo_ldflags -Wl,/MACHINE:ARM64";;
  esac

  # Chromium enables /SAFESEH for x86 with clang-cl, but CGO compiles gcc_386.S with GCC which does not support /SAFESEH.
  # So has to remove /SAFESEH for x86.
  if [ "$target_cpu" = 'x86' ]; then
    cgo_ldflags="$cgo_ldflags -Wl,/SAFESEH:NO"
  fi

  # Chromium uses lld-link separately, but CGO calls lld-link through clang, so linker options must be wrapped in clang options.
  escapelinkerflags() {
    for i in "$@"; do
      if echo "$i" | grep -q ','; then
        echo -n " -Xlinker $i"
      else
        echo -n " -Wl,$i"
      fi
    done
  }
  shared_ldflags="$cgo_ldflags $(escapelinkerflags $shared_ldflags)"
  static_ldflags="$cgo_ldflags $(escapelinkerflags $static_ldflags)"

  # xyz.lib must be wrapped in clang options
  shared_libs="./$shared_lib_name $(echo $shared_libs | sed 's/\([a-z0-9_]*\)\.lib/-l\1/g' )"
  static_libs="./$static_lib_name $(echo $static_libs | sed 's/\([a-z0-9_]*\)\.lib/-l\1/g' )"
elif [ "$ARCH" = 'Darwin' ]; then
  static_libs="./$static_lib_name $static_libs"
fi

if [ "$ARCH" = 'Linux' ]; then
  # Follows the order of tool("link") from build/toolchain/gcc_toolchain.gni
  shared_ldflags="$shared_ldflags $shared_solibs $shared_libs"
  static_ldflags="$static_ldflags $static_solibs $static_libs"
elif [ "$ARCH" = 'Windows' ]; then
  # Follows the order of tool("link") from build/toolchain/win/toolchain.gni
  shared_ldflags="$sys_lib_flags $shared_libs $shared_solibs $shared_ldflags"
  static_ldflags="$sys_lib_flags $static_libs $static_solibs $static_ldflags"
elif [ "$ARCH" = 'Darwin' ]; then
  # Follows the order of tool("link") from build/toolchain/apple/toolchain.gni
  shared_ldflags="$shared_ldflags $shared_frameworks $shared_solibs $shared_libs"
  static_ldflags="$static_ldflags $static_frameworks $static_solibs $static_libs"
fi

# CGO adds -marm, which conflicts with -mthumb used by various OpenWrt targets.
if [ "$target_cpu" = 'arm' ]; then
  cgo_cflags=$(echo "$cgo_cflags" | sed 's/ -mthumb / /g')
fi

buildmode_flag='-buildmode=pie'

if [ "$target_cpu" = 'mipsel' -o "$target_cpu" = 'mips64el' ]; then
  # CGO does not support PIE for linux/mipsle,mipe64le.
  buildmode_flag=
elif [ "$target_cpu" = 'arm64' -a "$ARCH" = 'Windows' ]; then
  # CGO does not support PIE for windows/arm64.
  buildmode_flag=
elif [ "$target_cpu" = 'x86' -a "$target_os" != 'android' ]; then
  # Segfaults if built with PIE in regular Linux.  TODO: Find out why.
  buildmode_flag=
fi

# Requires explicit -nopie otherwise clang adds -pie to lld sometime.
if [ ! "$buildmode_flag" ]; then
  shared_ldflags="$(echo "$shared_ldflags" | sed 's/ -pie / /g') -nopie"
  static_ldflags="$(echo "$static_ldflags" | sed 's/ -pie / /g') -nopie"
fi

# Avoids section type mismatch for .debug_info etc on MIPS.
# This is probably caused by different expectation between LLVM and CGO's GCC.
if [ "$target_cpu" = 'mipsel' -o "$target_cpu" = 'mips64el' ]; then
  shared_ldflags="$shared_ldflags -Wl,--strip-debug"
  static_ldflags="$static_ldflags -Wl,--strip-debug"
fi

# Allows running cronet_example test case without explicit LD_LIBRARY_PATH.
if [ "$ARCH" = 'Linux' ]; then
  shared_ldflags="$shared_ldflags -Wl,-rpath,\$ORIGIN"
fi

cat >out/Release/cronet/go_env.sh <<EOF
ARCH=$ARCH
target_cpu=$target_cpu
CLANG_REVISION=$CLANG_REVISION
WITH_CLANG=$WITH_CLANG
WITH_QEMU=$WITH_QEMU
WITH_ANDROID_IMG=$WITH_ANDROID_IMG
buildmode_flag=$buildmode_flag
[ "$WITH_GOOS" -a "$WITH_GOARCH" ] && export GOOS="$WITH_GOOS"
[ "$WITH_GOARCH" -a "$WITH_GOARCH" ] && export GOARCH="$WITH_GOARCH"
[ "$mips_float_abi" = "soft" ] && export GOMIPS=softfloat
export CGO_CFLAGS="$cgo_cflags"
export CGO_LDFLAGS="$cgo_ldflags"
EOF

cat >out/Release/cronet/link_shared.go <<EOF
package main

// #cgo LDFLAGS: $shared_ldflags
import "C"
EOF

cat >out/Release/cronet/link_static.go <<EOF
package main

// #cgo LDFLAGS: $static_ldflags
import "C"
EOF
