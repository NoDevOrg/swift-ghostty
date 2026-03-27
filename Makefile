xcframework:
	@echo "Installing zig via mise"
	@mise install
	@echo "Using zig v$(sh zig version)"
	@echo "Building Ghostty.xcframework"
	cd ghostty && zig build -Doptimize=ReleaseFast -Demit-xcframework -Dxcframework-target=native
	@echo "Building libghostty-vt"
	cd ghostty && zig build -Doptimize=ReleaseFast libghostty-vt
	@echo "Merging libghostty-vt into xcframework"
	libtool -static -o ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-merged.a \
		ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a \
		ghostty/zig-out/lib/libghostty-vt.a
	mv ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-merged.a \
		ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a
	@echo "Removing VT headers from xcframework (served by GhosttyVT target)"
	rm -rf ghostty/macos/GhosttyKit.xcframework/macos-arm64/Headers/ghostty
	zip -r Frameworks/GhosttyKit.xcframework.zip ghostty/macos/GhosttyKit.xcframework
	@echo "Syncing bundled themes"
	rsync -a --delete ghostty/zig-out/share/ghostty/themes/ Sources/Ghostty/Resources/Themes/
	@echo "Syncing VT headers"
	rsync -a --delete --exclude='key.h' --exclude='mouse.h' --exclude='key/' --exclude='mouse/' \
		--exclude='wasm.h' --exclude='build_info.h' --exclude='osc.h' --exclude='paste.h' \
		--exclude='sgr.h' --exclude='focus.h' --exclude='render.h' \
		ghostty/include/ghostty/vt/ Sources/GhosttyVT/include/ghostty/vt/
