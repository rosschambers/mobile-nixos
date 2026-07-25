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

  # Inject a ramoops reserved-memory node into our device DTS so PSTORE_RAM has a
  # region to write the kernel console/oops to. Without this the ramoops region is
  # uninitialised (we read back only 0x55 fill from lk2nd's `oem ramoops raw`), so
  # a crashing kernel leaves no log. Address 0xbfe00000 (size 2 MB) sits in free
  # RAM between the reserved SoC carveouts (top is 0x95002000) and rmtfs
  # (0xf2d00000), and covers the region lk2nd itself reports (console @ 0xbfec0000)
  # so lk2nd's `oem ramoops console` can read our kernel's log after a reboot.
  # The device DTS's reserved-memory node uses #size-cells=2 (inherited from
  # msm8953.dtsi), so reg is <hi lo hi lo>.
  postPatch = ''
    dts=arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts
    if grep -q "ramoops@" "$dts"; then
      echo ":: ramoops node already present in $dts"
    else
      echo ":: Injecting ramoops reserved-memory node into $dts"
      ${buildPackages.gnused}/bin/sed -i \
        's|\(\treserved-memory {\)|\1\n\t\tramoops@bfe00000 {\n\t\t\tcompatible = "ramoops";\n\t\t\treg = <0x0 0xbfe00000 0x0 0x200000>;\n\t\t\tconsole-size = <0x100000>;\n\t\t\tpmsg-size = <0x40000>;\n\t\t\trecord-size = <0x40000>;\n\t\t\tecc-size = <16>;\n\t\t};\n|' \
        "$dts"
      echo ":: ramoops node injected:"
      grep -A9 "ramoops@bfe00000" "$dts" || true
    fi

    # Inject a simple-framebuffer so the kernel can draw EARLY boot messages (and
    # a panic trace) to the panel using lk2nd's continuous-splash framebuffer,
    # BEFORE the msm DRM module loads. This is the pmOS-recommended early-console
    # method for Qualcomm mainline bring-up (wiki: MSM8996/SM7150 Mainlining) and
    # our most reliable debug channel (UART pads aren't accessible; lk2nd's
    # ramoops reader is broken for our address, upstream lk2nd#431).
    # Params from kaechele's DTS: cont_splash_mem @ 0x90001000, size 800*1280*3 →
    # 800x1280, 24bpp (3 bytes/px), stride 800*3=2400, format r8g8b8.
    # The node goes under /chosen (created if absent) with simplefb-<format>
    # compatible so FB_SIMPLE binds it; fbcon then prints on-screen from early boot.
    if grep -q "simple-framebuffer" "$dts"; then
      echo ":: simple-framebuffer already present in $dts"
    else
      echo ":: Injecting simple-framebuffer + chosen node into $dts"
      # Insert a chosen node with the framebuffer right after the root "model =" line.
      ${buildPackages.gnused}/bin/sed -i \
        's|\(\tmodel = "Lenovo ThinkView Smart";\)|\1\n\n\tchosen {\n\t\t#address-cells = <2>;\n\t\t#size-cells = <2>;\n\t\tranges;\n\n\t\tframebuffer@90001000 {\n\t\t\tcompatible = "simple-framebuffer";\n\t\t\treg = <0x0 0x90001000 0x0 (800 * 1280 * 3)>;\n\t\t\twidth = <800>;\n\t\t\theight = <1280>;\n\t\t\tstride = <(800 * 3)>;\n\t\t\tformat = "r8g8b8";\n\t\t};\n\t};|' \
        "$dts"
      echo ":: simple-framebuffer injected:"
      grep -A12 "chosen {" "$dts" | head -16 || true
    fi
  '';

  # drivers/gpu/drm/msm generates register headers at build time via
  # registers/gen_header.py, which imports `lxml` (for schema validation).
  # Without python3+lxml the msm-drm build fails with Error 127. We KEEP the
  # msm display driver (this device needs a screen), so provide the codegen tool.
  # MUST be buildPackages (native x86_64) — a cross-built aarch64 python cannot
  # run on the build host ("Exec format error").
  nativeBuildInputs = [ (buildPackages.python3.withPackages (ps: [ ps.lxml ])) ];
}
