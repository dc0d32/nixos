# Font rendering — slight hinting + RGB-off antialiasing via fontconfig.
#
# `mkDefault` on the fontconfig fields so a host can override hinting
# style without a `mkForce` fight. The fontconfig snippet under
# xdg.configFile is the actual policy file fontconfig reads at runtime.
#
# Migrated from modules/home/fonts.nix.
{ lib, ... }:
{
  flake.modules.homeManager.fonts = {
    fonts.fontconfig = {
      enable = lib.mkDefault true;
      hinting = lib.mkDefault "slight";
    };

    xdg.configFile."fontconfig/conf.d/10-rendering.conf".text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <match target="font">
          <edit name="antialias" mode="assign"><bool>true</bool></edit>
          <edit name="hinting" mode="assign"><bool>true</bool></edit>
          <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
          <edit name="rgba" mode="assign"><const>none</const></edit>
          <edit name="lcdfilter" mode="assign"><const>lcdnone</const></edit>
        </match>
      </fontconfig>
    '';
  };
}
