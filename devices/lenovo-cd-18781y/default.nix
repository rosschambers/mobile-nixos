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
    ''
  ;
in
{
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
      # Touchscreen controllers — the device ships one of two panels
      # (FT8201 or HX83100A), auto-detected; include both touch drivers.
      "focaltech_ts"            # FT8201 touch (verify module name in Task 4)
      "himax_hx83100a"          # HX83100A touch (verify module name in Task 4)
      "qcom-pon"                # volume keys (NOTE: no physical power button)
      # Panel modules for the two possible panels.
      "panel-lenovo-cd-18781y-ft8201"
      "panel-lenovo-cd-18781y-hx83100a"
      "msm"                     # DRM
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
  ];
}
