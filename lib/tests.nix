{
  lib,
  makeTest,
  eval-config,
  qemu-common-lib,
  ...
}:

let
  testLib = {
    # this takes a nixos config and changes the disk devices so we can run them inside the qemu test runner
    # basically changes all the disk.*.devices to something like /dev/vda or /dev/vdb etc.
    prepareDiskoConfig =
      cfg: devices:
      let
        cleanedTopLevel = lib.filterAttrsRecursive (n: _: !lib.hasPrefix "_" n) cfg;

        preparedDisks =
          lib.foldlAttrs
            (acc: n: v: {
              devices = lib.tail acc.devices;
              grub-devices =
                acc.grub-devices
                ++ (lib.optional (lib.any (part: (part.type or "") == "EF02") (
                  lib.attrValues (v.content.partitions or { })
                )) (lib.head acc.devices));
              disks = acc.disks // {
                "${n}" = v // {
                  device = lib.head acc.devices;
                  content = v.content // {
                    device = lib.head acc.devices;
                  };
                };
              };
            })
            {
              inherit devices;
              grub-devices = [ ];
              disks = { };
            }
            cleanedTopLevel.disko.devices.disk;
      in
      cleanedTopLevel
      // {
        boot.loader.grub.devices =
          if (preparedDisks.grub-devices != [ ]) then preparedDisks.grub-devices else [ "nodev" ];
        disko.devices = cleanedTopLevel.disko.devices // {
          disk = preparedDisks.disks;
        };
      };

    # list of devices generated inside qemu
    devices = [
      "/dev/vda"
      "/dev/vdb"
      "/dev/vdc"
      "/dev/vdd"
      "/dev/vde"
      "/dev/vdf"
      "/dev/vdg"
      "/dev/vdh"
      "/dev/vdi"
      "/dev/vdj"
      "/dev/vdk"
      "/dev/vdl"
      "/dev/vdm"
      "/dev/vdn"
      "/dev/vdo"
    ];

    # This is the test generator for a disko test
    makeDiskoTest =
      {
        name,
        disko-config,
        extendModules ? null,
        pkgs ? import <nixpkgs> { },
        extraTestScript ? "",
        bootCommands ? "",
        extraInstallerConfig ? { },
        extraSystemConfig ? { },
        efi ? !pkgs.stdenv.hostPlatform.isRiscV64,
        postDisko ? "",
        testMode ? "module", # can be one of direct module cli
        testBoot ? true, # if we actually want to test booting or just create/mount
        enableOCR ? false,
      }:
      let
        makeTest' =
          args:
          makeTest args {
            inherit pkgs;
            system = pkgs.stdenv.hostPlatform.system;
          };

        # Get qemu-common library functions for this pkgs
        qemu-common = qemu-common-lib pkgs;
        # qemuBinary returns a string like: "/nix/store/.../qemu-system-x86_64 -machine accel=kvm:tcg -cpu max"
        qemuBinaryString = qemu-common.qemuBinary pkgs.qemu_test;

        # for installation we skip /dev/vda because it is the test runner disk

        importedDiskoConfig = if builtins.isPath disko-config then import disko-config else disko-config;

        diskoConfigWithArgs =
          if builtins.isFunction importedDiskoConfig then
            importedDiskoConfig { inherit lib; }
          else
            importedDiskoConfig;

        # When extendModules is provided (from module.nix), we use it to merge
        # extraSystemConfig (which includes disko.tests.extraConfig from the NixOS config).
        #
        # For standalone tests, we extract disko.tests.extraConfig directly from the
        # disko-config file itself, allowing test files to embed their test-specific
        # NixOS configuration. This unifies the two code paths.
        #
        # The merged config is then passed to prepareDiskoConfig, so test-specific
        # disko overrides (like partition sizes, LUKS keys) are applied before
        # device path transformation.
        embeddedTestConfig = diskoConfigWithArgs.disko.tests.extraConfig or { };

        mergedDiskoConfig =
          if extendModules != null then
            # Module mode: use extendModules for proper NixOS module merging
            let
              mergedEval = extendModules { modules = [ extraSystemConfig ]; };
            in
            builtins.removeAttrs mergedEval.config [ "_module" ]
          else
            # Standalone mode: use eval-config to properly merge configs as modules
            let
              mergedEval = eval-config {
                modules = [
                  ../module.nix
                  diskoConfigWithArgs
                  embeddedTestConfig
                  extraSystemConfig
                ];
                system = pkgs.stdenv.hostPlatform.system;
              };
            in
            builtins.removeAttrs mergedEval.config [ "_module" ];

        testConfigInstall = testLib.prepareDiskoConfig mergedDiskoConfig (lib.tail testLib.devices);
        # we need to shift the disks by one because the first disk is the /dev/vda of the test runner
        # so /dev/vdb becomes /dev/vda etc.
        testConfigBooted = testLib.prepareDiskoConfig mergedDiskoConfig testLib.devices;

        tsp-generator = pkgs.callPackage ../. { checked = true; };
        tsp-format = (tsp-generator._cliFormat testConfigInstall) pkgs;
        tsp-mount = (tsp-generator._cliMount testConfigInstall) pkgs;
        tsp-unmount = (tsp-generator._cliUnmount testConfigInstall) pkgs;
        tsp-disko = (tsp-generator._cliDestroyFormatMount testConfigInstall) pkgs;
        tsp-config = tsp-generator.config testConfigBooted;
        num-disks = builtins.length (lib.attrNames testConfigBooted.disko.devices.disk);

        # Module containing the base disko configuration for the installed system
        # Only used when extendModules is NOT provided (standalone test mode)
        diskoModule =
          { config, ... }:
          {
            imports = [
              (lib.optionalAttrs (testMode == "direct") tsp-config)
              (lib.optionalAttrs (testMode == "module") {
                disko.enableConfig = true;
                imports = [
                  ../module.nix
                  testConfigBooted
                ];
              })
            ];

            # config for tests to make them run faster or work at all
            documentation.enable = false;
            hardware.enableAllFirmware = lib.mkForce false;
            # FIXME: we don't have an systemd in stage-1 equialvent for this
            boot.initrd.preDeviceCommands = lib.mkIf (!config.boot.initrd.systemd.enable) ''
              echo -n 'secretsecret' > /tmp/secret.key
            '';
            boot.consoleLogLevel = lib.mkForce 100;
            boot.loader.systemd-boot.enable = lib.mkDefault efi;
          };

        # Module containing test-specific configuration for the VM environment
        # This applies the QEMU device paths from prepareDiskoConfig
        testInstrumentationModule =
          { config, modulesPath, ... }:
          {
            imports = [
              (modulesPath + "/testing/test-instrumentation.nix") # we need these 2 modules always to be able to run the tests
              (modulesPath + "/profiles/qemu-guest.nix")
            ];

            # Apply the prepared disko config with QEMU device paths.
            # We use mkForce because the device paths MUST be the QEMU virtio devices,
            # but other disko settings (partition sizes, LUKS config, etc.) have already
            # been merged via extraSystemConfig before prepareDiskoConfig was called.
            disko.devices = lib.mkForce testConfigBooted.disko.devices;

            # since we boot on a different machine, the efi payload needs to be portable
            boot.loader.grub.efiInstallAsRemovable = efi;
            boot.loader.grub.efiSupport = efi;
            boot.loader.systemd-boot.graceful = true;

            # we always want the bind-mounted nix store. otherwise tests take forever
            fileSystems."/nix/store" = lib.mkForce {
              device = "nix-store";
              fsType = "9p";
              neededForBoot = true;
              options = [
                "trans=virtio"
                "version=9p2000.L"
                "cache=loose"
              ];
            };
            boot.zfs.devNodes = "/dev/disk/by-uuid"; # needed because /dev/disk/by-id is empty in qemu-vms

            # Silence mdadm warning about missing MAILADDR or PROGRAM
            boot.swraid.mdadmConf = "PROGRAM ${pkgs.coreutils}/bin/true";

            # grub will install to these devices, we need to force those or we are offset by 1
            # we use mkOveride 70, so that users can override this with mkForce in case they are testing grub mirrored boots
            boot.loader.grub.devices = lib.mkOverride 70 testConfigInstall.boot.loader.grub.devices;

            assertions = [
              {
                assertion =
                  builtins.length config.boot.loader.grub.mirroredBoots > 1 -> config.boot.loader.grub.devices == [ ];
                message = ''
                  When using `--vm-test` in combination with `mirroredBoots`,
                  it is necessary to configure `boot.loader.grub.devices` as an empty list by setting `boot.loader.grub.devices = lib.mkForce [];`.
                  This adjustment is crucial because the `--vm-test` mechanism automatically overrides the grub boot devices as part of the virtual machine test.
                '';
              }
            ];
          };

        # Use extendModules to merge configurations:
        # - If extendModules is provided, use it to extend an external NixOS configuration
        # - Otherwise, create a base evaluation from the disko config and extend that
        baseExtendModules =
          if extendModules != null then
            extendModules
          else
            (eval-config {
              modules = [ diskoModule ];
              system = pkgs.stdenv.hostPlatform.system;
            }).extendModules;

        # When extendModules is provided, extraSystemConfig has already been merged
        # into mergedDiskoConfig above, so we only add testInstrumentationModule here.
        # When extendModules is NOT provided, we add both.
        installed-system-eval = baseExtendModules {
          modules =
            [ testInstrumentationModule ]
            ++ lib.optional (extendModules == null) extraSystemConfig;
        };

        installedTopLevel = installed-system-eval.config.system.build.toplevel;

      in
      makeTest' {
        name = "disko-${name}";
        meta.timeout = 600; # 10 minutes
        inherit enableOCR;

        nodes.machine =
          { pkgs, ... }:
          {
            imports = [
              (lib.optionalAttrs (testMode == "module") {
                imports = [
                  ../module.nix
                ];
                disko = {
                  enableConfig = false;
                  checkScripts = true;
                  devices = testConfigInstall.disko.devices;
                };
              })
              extraInstallerConfig

              # from base.nix
              (
                { config, ... }:
                {
                  boot.supportedFilesystems = [
                    "btrfs"
                    "cifs"
                    "f2fs"
                    "jfs"
                    "ntfs"
                    "reiserfs"
                    "vfat"
                    "xfs"
                  ]
                  ++ lib.optional (
                    config.networking.hostId != null
                    && lib.meta.availableOn pkgs.stdenv.hostPlatform config.boot.zfs.package
                  ) "zfs";
                }
              )

              (
                if lib.versionAtLeast (lib.versions.majorMinor lib.version) "23.11" then
                  {
                    # From https://github.com/NixOS/nixpkgs/blob/7a8665e3a624a01b10d10d10b819cb1a8f34ee6e/nixos/modules/profiles/installation-device.nix#L116-L118
                    boot.swraid.enable = true;
                    # remove warning about unset mail
                    boot.swraid.mdadmConf = "PROGRAM ${pkgs.coreutils}/bin/true";
                  }
                else
                  {
                    boot.initrd.services.swraid.enable = true;
                  }
              )
            ];

            systemd.services.mdmonitor.enable = false; # silence some weird warnings

            environment.systemPackages = [
              pkgs.jq
            ];

            # speed-up eval
            documentation.enable = false;

            nix.settings = {
              substituters = lib.mkForce [ ];
              hashed-mirrors = null;
              connect-timeout = 1;
            };

            networking.hostId = lib.mkIf (
              (testConfigInstall ? networking.hostId) && (testConfigInstall.networking.hostId != null)
            ) testConfigInstall.networking.hostId;

            virtualisation.emptyDiskImages = builtins.genList (_: 4096) num-disks;

            # useful for debugging via repl
            system.build.systemToInstall = installed-system-eval;
          };

        testScript =
          { nodes, ... }:
          ''
            import shlex

            def disks(oldmachine, num_disks):
                disk_flags = []
                for i in range(num_disks):
                    disk_flags += [
                      '-drive',
                      f"file={oldmachine.state_dir}/empty{i}.qcow2,id=drive{i + 1},if=none,index={i + 1},werror=report",
                      '-device',
                      f"virtio-blk-pci,drive=drive{i + 1}"
                    ]
                return disk_flags

            def create_test_machine(
                oldmachine=None, **kwargs
            ):  # taken from <nixpkgs/nixos/tests/installer.nix>
                # Use qemu-common from nixpkgs to get the proper QEMU binary with correct machine type and flags
                # shlex.split properly handles the command string with options like "-machine virt,gic-version=max"
                start_command = shlex.split("${qemuBinaryString}") + [
                    "-m",
                    "1024",
                    "-virtfs",
                    "local,path=/nix/store,security_model=none,mount_tag=nix-store",
                    *disks(oldmachine, ${toString num-disks})
                ]
                ${lib.optionalString efi ''
                  start_command += ["-drive",
                    "if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.firmware}",
                    "-drive",
                    "if=pflash,format=raw,unit=1,readonly=on,file=${pkgs.OVMF.variables}"
                  ]
                ''}
                machine = create_machine(start_command=" ".join(start_command), **kwargs)
                driver.machines.append(machine)
                return machine

            machine.start()
            machine.succeed("echo -n 'additionalSecret' > /tmp/additionalSecret.key")
            machine.succeed("echo -n 'secretsecret' > /tmp/secret.key")
            ${lib.optionalString (testMode == "direct") ''
              # running direct mode
              machine.succeed("${lib.getExe tsp-format}")
              machine.succeed("${lib.getExe tsp-mount}")
              machine.succeed("${lib.getExe tsp-mount}") # verify that mount is idempotent
              machine.succeed("${lib.getExe tsp-unmount}")
              machine.succeed("${lib.getExe tsp-unmount}") # verify that umount is idempotent
              machine.succeed("${lib.getExe tsp-mount}") # verify that mount is idempotent
              machine.succeed("${lib.getExe tsp-disko} --yes-wipe-all-disks") # verify that we can destroy and recreate
              machine.succeed("mkdir -p /mnt/home")
              machine.succeed("touch /mnt/home/testfile")
              machine.succeed("${lib.getExe tsp-format}") # verify that format is idempotent
              machine.succeed("test -e /mnt/home/testfile")
            ''}
            ${lib.optionalString (testMode == "module") ''
              #  running module mode
              machine.succeed("${lib.getExe nodes.machine.system.build.format}")
              machine.succeed("${lib.getExe nodes.machine.system.build.mount}")
              machine.succeed("${lib.getExe nodes.machine.system.build.mount}") # verify that mount is idempotent
              machine.succeed("${lib.getExe nodes.machine.system.build.destroyFormatMount} --yes-wipe-all-disks") # verify that we can destroy and recreate again
              machine.succeed("mkdir -p /mnt/home")
              machine.succeed("touch /mnt/home/testfile")
              machine.succeed("${lib.getExe nodes.machine.system.build.format}") # verify that format is idempotent
              machine.succeed("test -e /mnt/home/testfile")
            ''}

            ${postDisko}

            ${lib.optionalString testBoot ''
              # mount nix-store in /mnt
              machine.succeed("mkdir -p /mnt/nix/store")
              machine.succeed("mount --bind /nix/store /mnt/nix/store")

              machine.succeed("nix-store --load-db < ${
                pkgs.closureInfo { rootPaths = [ installedTopLevel ]; }
              }/registration")

              # fix "this is not a NixOS installation"
              machine.succeed("mkdir -p /mnt/etc")
              machine.succeed("touch /mnt/etc/NIXOS")

              machine.succeed("mkdir -p /mnt/nix/var/nix/profiles")
              machine.succeed("nix-env -p /mnt/nix/var/nix/profiles/system --set ${installedTopLevel}")
              machine.succeed("NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root /mnt -- ${installedTopLevel}/bin/switch-to-configuration boot")
              machine.succeed("sync")
              machine.shutdown()

              machine = create_test_machine(oldmachine=machine, name="booted_machine")
              machine.start()
              ${bootCommands}
              machine.wait_for_unit("local-fs.target")
            ''}

            ${extraTestScript}
          '';
      };
  };
in
testLib
