{ pkgs, ... }: {
  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-color-emoji          # renamed from noto-fonts-emoji
      noto-fonts-cjk-sans
      inter
      jetbrains-mono
      # nerd fonts moved from pkgs.nerdfonts.override { fonts = [...]; } to
      # individual attrs under pkgs.nerd-fonts.<name>.
      nerd-fonts.jetbrains-mono
      nerd-fonts.fira-code
      # Rec Mono ships four variants (Casual/Linear/Duotone/Semicasual) in
      # one nixpkgs attr; fontconfig picks the variant by family name below.
      nerd-fonts.recursive-mono
    ];
    fontconfig.defaultFonts = {
      # Rec Mono Casual first; fall back to JetBrainsMono if a client can't
      # find the patched family (e.g. pre-patched tooling).
      monospace = [ "RecMonoCasual Nerd Font" "JetBrainsMono Nerd Font" ];
      sansSerif = [ "Inter" ];
      serif = [ "Noto Serif" ];
      emoji = [ "Noto Color Emoji" ];
    };
  };
}
