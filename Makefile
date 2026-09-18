# Convenience wrappers over the nimble tasks. The hermetic path is
# `nix build .#cbind` — the flake produces the same artifacts.

.PHONY: setup buildffi genbindings clean

setup:
	nimble -l setup -y

buildffi:
	nimble buildffi

genbindings:
	nimble genbindings_c

clean:
	rm -rf build nimcache nimcache_c c_bindings
