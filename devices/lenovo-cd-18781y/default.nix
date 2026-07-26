{ config, lib, pkgs, ... }:

# Lenovo ThinkSmart View (CD-18781Y), Qualcomm MSM8953 / APQ8053.
# Forked from devices/motorola-potter (same SoC + lk2nd flashing method).
# Chainloaded by our own signed lk2nd (see the thinksmart-nixos repo); the
# kernel boot image itself does NOT need AVB1 signing because lk2nd boots
# unsigned images.
#
# Ground truth for this device lives in the thinksmart-nixos repo docs
# (hardware.md: GPT, panels FT8201/HX83100A, no power button, 32 MB boot part).

let
  qcom-video-firmware =
    pkgs.runCommand "lenovo-cd-18781y-firmware" {} ''
      dir=$out/lib/firmware/qcom
      mkdir -p $dir
      cp ${pkgs.linux-firmware}/lib/firmware/qcom/a530* $dir
      # Adreno 506 ZAP shader — MUST be in the STAGE-1 firmware because the msm
      # DRM module is loaded from the initrd (stage-1 module list below), and its
      # one-shot GPU init requests the zap via request_firmware_direct() from the
      # INITRAMFS /lib/firmware. The rootfs copy is invisible at that point, so
      # with the zap absent here the GPU permanently failed hw init with -2
      # ("Unable to load a506_zap.mdt") even though the rootfs had the files —
      # the exact failure a530 avoids by being in this package. Path must match
      # the in-tree DTS zap-shader firmware-name:
      #   qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt
      # The .b00 split segment is NOT required (mdt_loader reads segment 0 and
      # the hash from within the .mdt itself; only .b02 is fetched separately) —
      # shipped anyway for completeness. Files are the self-consistent signed
      # stock set extracted from the golden vendor.bin backup (see the
      # thinksmart-nixos repo docs/log.md 2026-07-26).
      zap=$out/lib/firmware/qcom/msm8953/lenovo/cd-18781y
      mkdir -p $zap
      cp ${./firmware/a506_zap.mdt} $zap/a506_zap.mdt
      cp ${./firmware/a506_zap.b00} $zap/a506_zap.b00
      cp ${./firmware/a506_zap.b02} $zap/a506_zap.b02
    ''
  ;
in
{
  # Cross-compiling systemd (x86_64 -> aarch64) fails building its BPF programs:
  # clang -target bpf can't find linux/types.h / errno.h (a known nixpkgs cross
  # limitation — the kernel/libc header paths don't reach the BPF-target compile,
  # even though linux-headers is a buildInput). The BPF framework only powers
  # optional sandboxing (RestrictFileSystems, socket-bind restrictions) that a
  # thin voice-satellite appliance doesn't need. Disable it so the rootfs builds.
  # systemd's mesonFlags carry -Dbpf-framework=enabled; flip it to disabled.
  nixpkgs.overlays = [
    (final: prev: {
      systemd = prev.systemd.overrideAttrs (old: {
        mesonFlags = (lib.remove "-Dbpf-framework=enabled" (old.mesonFlags or []))
          ++ [ "-Dbpf-framework=disabled" ];
      });
    })
  ];

  mobile.device.name = "lenovo-cd-18781y";
  mobile.device.identity = {
    name = "ThinkSmart View";
    manufacturer = "Lenovo";
  };
  # Flip to "best-effort" once it boots (M2+).
  mobile.device.supportLevel = "broken";

  mobile.hardware = {
    soc = "qualcomm-msm8953";
    ram = 1024 * 2;
    # 8" 1280x800 panel. Native orientation TBD on first display bring-up.
    screen = {
      width = 1280; height = 800;
    };
  };

  mobile.boot.stage-1.firmware = [
    qcom-video-firmware
  ];

  mobile.boot.stage-1.kernel = {
    package = pkgs.callPackage ./kernel { };
    modular = true;
    modules = [
      "qcom-pon"                # volume keys (NOTE: no physical power button)
      # Panel modules — the device ships one of several panels, auto-detected.
      # All three exist in the kernel output (verified against lib/modules).
      "panel-lenovo-cd-18781y-ft8201"
      "panel-lenovo-cd-18781y-hx83100a"
      "panel-lenovo-cd-18781y-jd9365"
      # The full msm display stack: with REGULATOR_QCOM_LABIBB and
      # BACKLIGHT_QCOM_WLED now in the kernel, the panel driver can finally
      # probe (it consumes lab/ibb + wled), the DSI component attaches, msm
      # binds, and fbcon moves to the real DRM framebuffer with a properly
      # driven backlight. (Leaving these drivers present WITHOUT msm bound is
      # itself broken: the regulator framework's late cleanup powers off the
      # "unused" panel supplies → completely dark panel, as observed.)
      "msm"
      # NOTE: no touch modules — no focaltech_ts/himax_hx83100a .ko exists in
      # this tree (those were guessed names), and kaechele's DTS ships both
      # touchscreen nodes status="disabled" anyway. Revisit touch at M3/M4.
    ];
  };

  # linux-firmware + wireless-regdb also needed at configuration.nix level.
  # WiFi/BT is Qualcomm WCN36xx (QCA9379) per the in-tree DTS — needs the
  # wcn36xx firmware blob (wlanmdsp.mbn) from linux-firmware. (potter shipped a
  # firmware/ callPackage; we start without it — enable once we know exactly
  # which blobs boot needs. See Task 4.)
  mobile.device.enableFirmware = false;

  mobile.system.android.device_name = "lenovo-cd-18781y";
  mobile.system.android = {
    # The rootfs (1.77 GB) does NOT fit the 1.5 GB `system` partition, so we
    # install it to `userdata` (~4 GB) instead. Stage-1 mounts root by filesystem
    # label (NIXOS_SYSTEM) via /dev/disk/by-label, so it finds the rootfs wherever
    # it physically lives — this option just tells the flash tooling/docs where to
    # write system.img. See docs/log.md 2026-07-25 (size mismatch).
    system_partition_destination = "userdata";

    # MSM8953 defaults (same as potter). Verify against our GPT in Task 7.
    bootimg.flash = {
      offset_base = "0x80000000";
      offset_kernel = "0x00008000";
      offset_ramdisk = "0x01000000";
      offset_second = "0x00f00000";
      offset_tags = "0x00000100";
      pagesize = "2048";
    };
    appendDTB = [
      "dtbs/qcom/apq8053-lenovo-cd-18781y.dtb"
    ];
  };

  # DEBUG: stage-1's failure handler shows the error (code/title/message) on the
  # framebuffer then REBOOTS after fail.delay (default 10s) — that's why we saw the
  # boot UI + spinner then blank. Disable the auto-reboot so the error screen STAYS
  # up indefinitely and we can finally read/photograph the actual failure message.
  # Revert once we've read the error and it boots.
  mobile.boot.stage-1.fail.reboot = false;

  # DEBUG: disable the LVGL splash/progress GUI. It COVERS the console, hiding
  # the stage-1 task log — we could only see "Mobile NixOS" + a stuck empty bar.
  # With the GUI off, stage-1 logs print as plain text on the simplefb console,
  # showing exactly which task runs/hangs (e.g. waiting for the rootfs device).
  # Re-enable once boot works.
  mobile.boot.stage-1.gui.enable = false;

  # Our boot partition is 32 MB (0x1f80000), roomier than potter's 16 MB, so
  # gzip is fine; keep xz to be safe on size.
  mobile.boot.stage-1.compression = lib.mkDefault "xz";

  mobile.usb = {
    mode = "gadgetfs";
    idVendor = "18D1";  # Google
    idProduct = "4EE7"; # not lk2nd/fastboot's d00d, to distinguish NixOS
    gadgetfs.functions = {
      rndis = "rndis.usb0";
      adb = "ffs.adb";
    };
  };

  mobile.system.type = "android";
  mobile.system.android.flashingMethod = "lk2nd";

  # Serial + on-screen console for M1/M2 debugging. The console UART is uart_0
  # (serial@78af000, "uart_console_active" pinctrl, TX on GPIO5 pins A8/B8) →
  # ttyMSM0 @ 115200. earlycon gets output as early as possible. We also keep
  # tty0 (framebuffer) so anything the panel shows is a console too. NOTE: the
  # physical UART is on GPIO testpoints, not the USB-C port (uart_5 there is the
  # QCA9379 Bluetooth). If we can't reach the pads, PSTORE/ramoops (enabled in
  # structuredConfig below) preserves the last crash log across a reboot.
  boot.kernelParams = [
    "earlycon"
    "console=ttyMSM0,115200n8"
    "console=tty0"
    "loglevel=7"
    # DEBUG (temporary, pair with the blacklisted "msm" module above):
    # - modprobe.blacklist=msm: keep the msm DRM driver from loading so it never
    #   takes over and wipes the simple-framebuffer console (we saw text flash then
    #   go blank when it loaded). Lets the boot log / panic stay on the panel.
    # - panic=0: on a kernel panic, halt instead of rebooting, so the trace freezes
    #   on screen to read/photograph instead of vanishing in a reboot loop.
    # hci_uart/btqca: BT is modular and NOT in the initrd, yet hci0 firmware-retry
    # errors flooded the console — proof those modules loaded from the REAL rootfs,
    # i.e. stage-1 mounted it and stage-2 udev was running. The spam (missing
    # qca/rampatch firmware, an M4 item) drowns out the real boot log; silence it
    # until we wire BT firmware.
    "modprobe.blacklist=hci_uart,btqca"
    "panic=0"
    # - clk_ignore_unused / pd_ignore_unused: with msm blacklisted, NOTHING claims
    #   the MDSS display clocks/power-domains that lk2nd left running for the
    #   splash framebuffer — so late-init clk_disable_unused shuts them off and the
    #   panel stops scanning out (~1s in: text flashes then screen goes dark, which
    #   is exactly what we observed). Keep unclaimed clocks/domains ON so simplefb
    #   keeps displaying the console for the whole boot. Standard pmOS mainline
    #   bring-up params for exactly this situation.
    "clk_ignore_unused"
    "pd_ignore_unused"
  ];

  mobile.kernel.structuredConfig = [
    (helpers: with helpers; {
      CC_OPTIMIZE_FOR_PERFORMANCE = no;
      CC_OPTIMIZE_FOR_SIZE = yes;
    })
    # mobile-nixos requires these networking/netfilter options built-in (=y);
    # the msm8953 defconfig ships them as modules (=m). Force =y. (Not
    # hardware-specific — standard NixOS networking requirements.)
    (helpers: with helpers; {
      BRIDGE = yes;
      BRIDGE_NETFILTER = yes;
      IP6_NF_IPTABLES = yes;
      IP6_NF_RAW = yes;
      NETFILTER_XT_MATCH_HASHLIMIT = yes;
      NETFILTER_XT_MATCH_PHYSDEV = yes;
      NETFILTER_XT_MATCH_SOCKET = yes;
      NFT_BRIDGE_META = yes;
      NFT_BRIDGE_REJECT = yes;
      NFT_REJECT = yes;
      NFT_REJECT_IPV4 = yes;
      NFT_REJECT_IPV6 = yes;
      NFT_REJECT_NETDEV = yes;
      NFT_SOCKET = yes;
      NFT_TPROXY = yes;
      NF_TABLES_BRIDGE = yes;
      NF_TPROXY_IPV6 = yes;
    })
    # Lean-down: the seed config came from arm64 defconfig, which pulls in
    # hundreds of drivers for other SoCs/vendors (nouveau, iwlwifi, mlx5,
    # mediatek, ...) — ~8000 objects and driver-compile failures we don't care
    # about. Disable the big UNUSED families only. We KEEP DRM_MSM (this device
    # needs a display for the dashboard + voice satellite); the msm-drm
    # build-time codegen (gen_header.py) is satisfied by adding python3 to the
    # kernel build inputs (see kernel/default.nix), NOT by disabling the driver.
    (helpers: with helpers; {
      # Other-vendor / other-SoC GPUs (we use msm/adreno — keep DRM_MSM ON)
      DRM_NOUVEAU = no;
      DRM_AMDGPU = no;
      DRM_I915 = no;
      DRM_RADEON = no;
      # Wireless we don't use (device is wcn36xx)
      WLAN_VENDOR_INTEL = no;
      WLAN_VENDOR_MEDIATEK = no;
      WLAN_VENDOR_RALINK = no;
      WLAN_VENDOR_REALTEK = no;
      WLAN_VENDOR_MARVELL = no;
      WLAN_VENDOR_BROADCOM = no;
      # Other-vendor ethernet (this is a wifi-only device)
      NET_VENDOR_MELLANOX = no;
      NET_VENDOR_INTEL = no;
      NET_VENDOR_BROADCOM = no;
      NET_VENDOR_FREESCALE = no;
      NET_VENDOR_STMICRO = no;
      # Other ARM platforms' pinctrl/clk we don't need
      ARCH_MEDIATEK = no;
      ARCH_ROCKCHIP = no;
      ARCH_TEGRA = no;
      ARCH_EXYNOS = no;
    })
    # Debugging essentials for first boot (M1/M2):
    # - msm serial driver built-in so earlycon + console=ttyMSM0 work from the
    #   very start (a module would be too late for early boot).
    # - PSTORE/ramoops: preserve the last kernel log across a reboot, so even if
    #   we can't physically reach the UART pads we can read WHY it died after a
    #   power-cycle back into a working state.
    (helpers: with helpers; {
      SERIAL_MSM = yes;
      SERIAL_MSM_CONSOLE = yes;
      SERIAL_EARLYCON = yes;
      PSTORE = yes;
      PSTORE_RAM = yes;
      PSTORE_CONSOLE = yes;
    })
    # ON-SCREEN CONSOLE (our most reliable debug channel — the UART pads need
    # soldering and lk2nd's ramoops reader is broken for our address, upstream
    # issue msm8916-mainline/lk2nd#431). Observed: Lenovo logo → black screen with
    # the BACKLIGHT ON. So the panel powers up but no console text is drawn. The
    # kernel lacked a framebuffer console, so console=tty0 had nowhere to draw.
    # Wire fbcon so kernel messages render on the panel once DRM_MSM loads:
    # - DRM_FBDEV_EMULATION: DRM exposes /dev/fb0 for the console to draw on.
    # - FRAMEBUFFER_CONSOLE (+ DETECT_PRIMARY): fbcon binds to that framebuffer.
    # NOTE: we do NOT force DRM_MSM=y — kconfig drags it back to =m via a =m
    # dependency (QCOM_LLCC), failing validation. As a module it loads a few
    # seconds into boot; fbcon then activates and late kernel messages + any
    # userspace output appear on-screen. Early-boot messages before the module
    # loads won't show, but a panic at/after userspace will.
    (helpers: with helpers; {
      DRM_FBDEV_EMULATION = yes;
      FB = yes;
      # FB_SIMPLE: bind the simple-framebuffer node (injected into the DTS via the
      # kernel postPatch) to lk2nd's continuous-splash framebuffer at 0x90001000,
      # giving on-screen kernel output from EARLY boot — before the msm DRM module
      # loads. This is our primary debug channel.
      FB_SIMPLE = yes;
      FRAMEBUFFER_CONSOLE = yes;
      FRAMEBUFFER_CONSOLE_DETECT_PRIMARY = yes;
      VT = yes;
      VT_CONSOLE = yes;
    })
    # Audio + WiFi are already carried by the msm8953.config fragment in the base
    # config.aarch64 (SND_SOC_MSM8916_*, WCN36XX=m, WLAN_VENDOR_ATH=y). We do NOT
    # re-declare them here: mobile-nixos's validator requires every structuredConfig
    # key to also appear literally in the base config, and some of these audio
    # sub-options get pruned by kconfig dependency resolution (e.g.
    # SND_SOC_MSM8916_QDSP6) — declaring them then trips "expected =m but not
    # present". They build fine from the base config; revisit only if audio/wifi
    # are actually missing at M4. WiFi still needs the wlanmdsp.mbn firmware blob
    # wired via mobile.device.firmware at M4.
  ];
}
