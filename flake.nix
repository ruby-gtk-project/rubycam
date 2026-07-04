{
  description = "rubycam — Ruby V4L2 webcam library + GTK4 viewer";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          # ruby-gnome gems resolve Requires.private in .pc files, so pull in
          # the GTK stack's own build environments rather than enumerating
          # every transitive dev library.
          inputsFrom = with pkgs; [ gtk4 glib cairo pango gdk-pixbuf at-spi2-core ];

          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = with pkgs; [
            ruby_3_4
            libyaml
            openssl
            gtk4
            at-spi2-core # provides atk.pc for the atk gem
            expat # fontconfig's Requires.private, needed by the cairo gem
            xorg.libXdmcp # libxcb's Requires.private
            libselinux # libmount's Requires.private chain (gio2)
            libsepol
            libdatrie # libthai's Requires.private (pango)
            libdeflate # libtiff's Requires.private (gdk-pixbuf, gtk4)
            lerc # more libtiff Requires.private
            xz
            zstd
            libwebp
            gobject-introspection
          ];

          shellHook = ''
            export GEM_HOME="$PWD/.gem"
            export GEM_PATH="$GEM_HOME"
            export PATH="$GEM_HOME/bin:$PATH"
            export BUNDLE_PATH="$GEM_HOME"
            export BUNDLE_BIN="$GEM_HOME/bin"
          '';
        };
      }
    );
}
