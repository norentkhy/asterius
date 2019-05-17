{ pkgs ? import <nixpkgs> {}
, iohk-extras ? {}
, iohk-module ? {}
, haskell
, ...
}:
let
  # our packages
  # plan-pkgs = import ./pkgs.nix;
  plan-nix = haskell.cabalProjectToNix {
    src = ./..;
    ghc = pkgs.haskell.compiler.ghc864;
    hackageIndexState = "2019-05-10T00:00:00Z";
  };
  plan-pkgs = import "${plan-nix}/nix-plan/pkgs.nix";

  # Build the packageset with module support.
  # We can essentially override anything in the modules
  # section.
  #
  #  packages.cbors.patches = [ ./one.patch ];
  #  packages.cbors.flags.optimize-gmp = false;
  #
  compiler = (plan-pkgs.extras {}).compiler or
             (plan-pkgs.pkgs {}).compiler;

  pkgSet = haskell.mkCabalProjectPkgSet {
    inherit plan-pkgs;
    # The extras allow extension or restriction of the set of
    # packages we are interested in. By using the stack-pkgs.extras
    # we restrict our package set to the ones provided in stack.yaml.
    pkg-def-extras = [
      iohk-extras.${compiler.nix-name}
    ];
    modules = [
      # the iohk-module will supply us with the necessary
      # cross compilation plumbing to make Template Haskell
      # work when cross compiling.  For now we need to
      # list the packages that require template haskell
      # explicity here.
      iohk-module
      ({ config, ...}: {
          # packages.hsc2hs.components.exes.hsc2hs.doExactConfig = true;
          packages.ghc.patches = [ ./patches/ghc.patch ];
      })
    ];
  };
  # Patch file that can be applied to the full ghc tree
  # full-ghc-patch = pkgs.copyPathToStore ./patches/ghc/asterius.patch;
  ghc-head = let
    # Only gitlab has the right submoudle refs (the ones in github mirror do not work)
    # and only fetchgit seems to get the submoudles from gitlab
    ghc-src = pkgs.fetchgit {
      url = "https://gitlab.haskell.org/ghc/ghc";
      rev = "bf6dbe3d1046573cb71fd534a326a9a0e6f1b220";
      sha256 = "1hyq37vdicri96k05fm4w1ikdb87c430dh4aiy6ml9i3xzyxjdva";
      fetchSubmodules = true;
    };
    # The patched libs are currently in the repo
    boot-libs = pkgs.copyPathToStore ../ghc-toolkit/boot-libs;
    # Derive the patch using diff
    patch = pkgs.runCommand "asterius-libs-patch" {
      preferLocalBuild = true;
    } ''
      tmp=$(mktemp -d)
      cd $tmp
      cp -r ${ghc-src}/libraries old
      ln -s ${boot-libs} new
      chmod +w -R old
      mkdir -p old/rts/sm
      cd new
      find rts -type f -not -name rts.conf -exec cp ${ghc-src}/"{}" $tmp/old/"{}" \;
      cd $tmp
      for new in new/*; do
        (diff -Nu -r old/$(basename $new) $new || true) >> $out
      done
    '';
  in { inherit ghc-src boot-libs patch; };
  ghc864 = let
    ghc-src = pkgs.srcOnly pkgs.haskell.compiler.ghc864;
    ghc-prim = builtins.fetchTarball {
      url = "http://hackage.haskell.org/package/ghc-prim-0.5.3/ghc-prim-0.5.3.tar.gz";
    };
      sha256 = "1inn9dr481bwddai9i2bbk50i8clzkn4452wgq4g97pcgdy1k8mn";
    patch = pkgs.copyPathToStore ./patches/ghc/ghc864-libs.patch;
    ghc-patched-src = pkgs.runCommand "asterius-ghc864-ghc-patched-src" {
      buildInputs = [];
      preferLocalBuild = true;
    } ''
      set +x
      cp -r ${ghc-src} $out
      chmod +w -R $out
      cd $out
      cp -r rts libraries
    '';
    boot-libs = pkgs.runCommand "asterius-ghc864-boot-libs" {
      buildInputs = [];
      preferLocalBuild = true;
    } ''
      set +x
      cp -r ${ghc-patched-src} $out
      chmod +w -R $out
      cd $out/libraries
      patch -p1 < ${patch} || true
      # TODO find a better way to get these
      cp ${ghc-prim}/GHC/Prim.hs ghc-prim/GHC/Prim.hs
      cp ${ghc-prim}/GHC/PrimopWrappers.hs ghc-prim/GHC/PrimopWrappers.hs
      # TODO figure out a better way remove the unwanted stuff from ghc-prim.cabal
      sed -i '96,$ d' ghc-prim/ghc-prim.cabal
  '';
  in { inherit ghc-src ghc-prim ghc-patched-src boot-libs; };

in
  pkgSet.config.hsPkgs // {
    _config = pkgSet.config;
    inherit ghc-head ghc864 plan-nix;
    asterius-boot = pkgs.runCommand "asterius-boot" {
      preferLocalBuild = true;
      nativeBuildInputs = [ pkgs.makeWrapper pkgs.haskell.compiler.${compiler.nix-name} pkgs.autoconf  ];
    } ''
      mkdir -p $out/bin
      mkdir -p $out/boot
      ${pkgs.lib.concatMapStringsSep "\n" (exe: ''
        makeWrapper ${pkgSet.config.hsPkgs.asterius.components.exes.${exe}}/bin/${exe} $out/bin/${exe} \
          --set asterius_bindir $out/bin \
          --set asterius_bootdir $out/boot \
          --set boot_libs_path ${ghc864.boot-libs} \
          --set sandbox_ghc_lib_dir $(ghc --print-libdir)
      '') (pkgs.lib.attrNames pkgSet.config.hsPkgs.asterius.components.exes)}
      $out/bin/ahc-boot
    '';
  }