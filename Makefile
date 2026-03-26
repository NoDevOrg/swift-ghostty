xcframework:
	@echo "Installing zig via mise"
	@mise install
	@echo "Using zig v$(sh zig version)"
	@echo "Building Ghostty.xcframework"
	cd ghostty && zig build -Doptimize=ReleaseFast -Demit-xcframework -Dxcframework-target=native
	zip -r Frameworks/GhosttyKit.xcframework.zip ghostty/macos/GhosttyKit.xcframework
	@echo "Syncing bundled themes"
	rsync -a --delete ghostty/zig-out/share/ghostty/themes/ Sources/Ghostty/Resources/Themes/
