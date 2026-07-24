{ mobile-nixos
, fetchFromGitHub
, buildPackages
, ...
}:

# msm8953-mainline/linux, branch 6.12/main — this branch carries the in-tree
# device tree `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts`
# (kaechele's PR #221 "Add Lenovo ThinkSmart View" landed here), plus the
# HX83100A / FT8201 touch + panel support. So the kernel DTS is NOT authored by
# us — it ships in this tree. Config is seeded from the tree's msm8953.config +
# defconfig; mobile-nixos's hardware-qualcomm structuredConfig fills SoC basics.

mobile-nixos.kernel-builder {
  version = "6.12.0";
  configfile = ./config.aarch64;

  src = fetchFromGitHub {
    owner = "msm8953-mainline";
    repo = "linux";
    rev = "d9eabbae3edea6adb08e74c30059aa0933afaae7";  # branch 6.12/main @ 2026-07-24
    sha256 = "sha256-6WD0G2H++6EVlaSf9cXvGOCVGWUzmWxm4Xlnfu6+p2Q=";
  };

  isModular = true;

  # drivers/gpu/drm/msm generates register headers at build time via
  # registers/gen_header.py, which imports `lxml` (for schema validation).
  # Without python3+lxml the msm-drm build fails with Error 127. We KEEP the
  # msm display driver (this device needs a screen), so provide the codegen tool.
  # MUST be buildPackages (native x86_64) — a cross-built aarch64 python cannot
  # run on the build host ("Exec format error").
  nativeBuildInputs = [ (buildPackages.python3.withPackages (ps: [ ps.lxml ])) ];
}
