.PHONY: app install release icon clean

# Build build/RawViewer.app
app:
	./scripts/build-app.sh

# Build and copy into /Applications
install:
	./scripts/install.sh

# Developer ID signing, notarization and dist/RawViewer-<version>.zip
release:
	./scripts/release.sh

# Regenerate Resources/AppIcon.icns
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build dist
