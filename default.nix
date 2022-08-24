{ lib ? import <nixpkgs/lib> }:
with lib;
with builtins;

let

  helper.find-device = device: let
    environment = helper.device-id device;
  in
    # DEVICE points already to /dev/disk, so we don't handle it via /dev/disk/by-path
    if hasPrefix "/dev/disk" device then
       "${environment}='${device}'"
    else ''
      ${environment}=$(for x in $(find /dev/disk/{by-path,by-id}/); do
        dev=$x
        if [ "$(readlink -f $x)" = "$(readlink -f '${device}')" ]; then
          target=$dev
          break
        fi
      done
      if test -z ''${target+x}; then
        echo 'unable to find path of disk: ${device}, bailing out' >&2
        exit 1
      else
        echo $target
      fi)
    '';

  helper.device-id = device: "DEVICE${builtins.substring 0 5 (builtins.hashString "sha1" device)}";

  config-f = q: x: config.${x.type} q x;

  config.filesystem = q: x: {
    fileSystems.${x.mountpoint} = {
      device = q.device;
      fsType = x.format;
      ${if x ? options then "options" else null} = x.options;
    };
  };

  config.devices = q: x:
    foldl' recursiveUpdate {} (mapAttrsToList (name: config-f { device = "/dev/${name}"; }) x.content);

  config.luks = q: x: {
    boot.initrd.luks.devices.${x.name}.device = q.device;
  } // config-f { device = "/dev/mapper/${x.name}"; } x.content;

  config.lv = q: x:
    config-f { device = "/dev/mapper/${q.vgname}-${q.name}"; } x.content;

  config.lvm = q: x:
    foldl' recursiveUpdate {} (mapAttrsToList (name: config-f { inherit name; vgname = x.name; }) x.lvs);

  config.noop = q: x: {};

  config.partition = q: x:
    config-f { device = q.device + toString q.index; } x.content;

  config.table = q: x:
    foldl' recursiveUpdate {} (imap (index: config-f (q // { inherit index; })) x.partitions);


  create-f = q: x: create.${x.type} q x;

  create.filesystem = q: x: ''
    mkfs.${x.format} ${q.device}
  '';

  create.devices = q: x: let
    raid-devices = lib.filterAttrs (_: dev: dev.type == "mdadm") x.content;
    other-devices = lib.filterAttrs (_: dev: dev.type != "mdadm") x.content;
  in ''
    ${concatStrings (mapAttrsToList (name: create-f { device = "/dev/${name}"; }) other-devices)}
    ${concatStrings (mapAttrsToList (name: create-f { device = "/dev/${name}"; name = name; }) raid-devices)}
  '';

  create.mdraid = q: x: ''
    RAIDDEVICES_N_${x.name}=$((''${RAIDDEVICES_N_${x.name}:-0}+1))
    RAIDDEVICES_${x.name}="''${RAIDDEVICES_${x.name}:-}${q.device} "
  '';

  create.mdadm = q: x: ''
    echo 'y' | mdadm --create /dev/md/${q.name} --level=${toString x.level or 1} --raid-devices=''${RAIDDEVICES_N_${q.name}} ''${RAIDDEVICES_${q.name}}
    udevadm trigger --subsystem-match=block; udevadm settle
    ${create-f { device = "/dev/md/${q.name}"; } x.content}
  '';

  create.luks = q: x: ''
    cryptsetup -q luksFormat ${q.device} ${if builtins.hasAttr "keyfile" x then x.keyfile else ""} ${toString (x.extraArgs or [])}
    cryptsetup luksOpen ${q.device} ${x.name} ${if builtins.hasAttr "keyfile" x then "--key-file " + x.keyfile else ""}
    ${create-f { device = "/dev/mapper/${x.name}"; } x.content}
  '';

  create.lv = q: x: ''
    lvcreate ${if hasInfix "%" x.size then "-l" else "-L"} ${x.size} -n ${q.name} ${q.vgname}
    ${create-f { device = "/dev/mapper/${q.vgname}-${q.name}"; } x.content}
  '';

  create.lvm = q: x: ''
    pvcreate ${q.device}
    vgcreate ${x.name} ${q.device}
    ${concatStrings (mapAttrsToList (name: create-f { inherit name; vgname = x.name; }) x.lvs)}
  '';

  create.noop = q: x: "";

  create.partition = q: x: let
    env = helper.device-id q.device;
  in ''
    parted -s "''${${env}}" mkpart ${x.part-type} ${x.fs-type or ""} ${x.start} ${x.end}
    # ensure /dev/disk/by-path/..-partN exists before continuing
    udevadm trigger --subsystem-match=block; udevadm settle
    ${optionalString (x.bootable or false) ''
      parted -s "''${${env}}" set ${toString q.index} boot on
    ''}
    ${concatMapStringsSep "" (flag: ''
      parted -s "''${${env}}" set ${toString q.index} ${flag} on
    '') (x.flags or [])}
    ${create-f { device = "\"\${${env}}\"-part" + toString q.index; } x.content}
  '';

  create.table = q: x: ''
    ${helper.find-device q.device}
    parted -s "''${${helper.device-id q.device}}" mklabel ${x.format}
    ${concatStrings (imap (index: create-f (q // { inherit index; })) x.partitions)}
  '';


  mount-f = q: x: mount.${x.type} q x;

  mount.filesystem = q: x: {
      fs.${x.mountpoint} = ''
        if ! findmnt ${q.device} "/mnt${x.mountpoint}" > /dev/null 2>&1; then
          mount ${q.device} "/mnt${x.mountpoint}" -o X-mount.mkdir
        fi
      '';
    };

  mount.devices = q: x: let
    z = foldl' recursiveUpdate {} (mapAttrsToList (name: mount-f { device = "/dev/${name}"; }) x.content);
    # attrValues returns values sorted by name.  This is important, because it
    # ensures that "/" is processed before "/foo" etc.
  in ''
    ${optionalString (hasAttr "table" z) (concatStringsSep "\n" (attrValues z.table))}
    ${optionalString (hasAttr "luks" z) (concatStringsSep "\n" (attrValues z.luks))}
    ${optionalString (hasAttr "lvm" z) (concatStringsSep "\n" (attrValues z.lvm))}
    ${optionalString (hasAttr "fs" z) (concatStringsSep "\n" (attrValues z.fs))}
  '';

  mount.luks = q: x: (
    recursiveUpdate
    (mount-f { device = "/dev/mapper/${x.name}"; } x.content)
    {luks.${q.device} = ''
      cryptsetup luksOpen ${q.device} ${x.name} ${if builtins.hasAttr "keyfile" x then "--key-file " + x.keyfile else ""}
    '';}
  );

  mount.lv = q: x:
    mount-f { device = "/dev/mapper/${q.vgname}-${q.name}"; } x.content;

  mount.lvm = q: x: (
    recursiveUpdate
    (foldl' recursiveUpdate {} (mapAttrsToList (name: mount-f { inherit name; vgname = x.name; }) x.lvs))
    {lvm.${q.device} = ''
      vgchange -a y
    '';}
  );

  mount.noop = q: x: {};

  # TODO maybe we need to do something here?
  mount.mdadm = mount.noop;
  mount.mdraid = mount.noop;

  mount.partition = q: x:
    mount-f { device = "\"\${${q.device}}\"-part" + toString q.index; } x.content;

  mount.table = q: x: (
    recursiveUpdate
    (foldl' recursiveUpdate {} (imap (index: mount-f (q // { inherit index; device = helper.device-id q.device; })) x.partitions))
    {table.${q.device} = helper.find-device q.device;}
  );
in {
  config = config-f {};
  create = cfg: ''
    set -efux
    ${create-f {} cfg}
  '';
  mount = cfg: ''
    set -efux
    ${mount-f {} cfg}
  '';

}