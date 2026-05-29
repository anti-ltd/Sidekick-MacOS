#!/usr/bin/env bash
# Patch the broken macOS slice of stasel/WebRTC.
#
# Background: the prebuilt WebRTC.xcframework from stasel/WebRTC ships a
# macOS slice that contains only the umbrella `WebRTC.h` — none of the
# 90-odd headers it #imports are present in the macos-* directories.
# (Upstream issue stasel/WebRTC#145.) The iOS slice ships them all, and
# the macOS binary actually exports every class we need (including
# RTCMTLNSVideoView) — just no header for it.
#
# What this script does:
#   1. Copies every iOS slice header into the macOS slice.
#   2. Rewrites WebRTC.h to drop iOS-only headers (UIKit, AVAudioSession).
#   3. Drops a small custom RTCMTLNSVideoView.h declaring the macOS-only
#      Metal renderer that ships in the binary but not in headers.
#
# Idempotent — running it twice does nothing on the second pass. Safe to
# run unconditionally before `swift build` (the Makefile's `build` target
# calls it).
#
# Usage: patch-webrtc-macos.sh [SCRATCH_PATH]
#   SCRATCH_PATH defaults to the repo's own .build. appstage passes its
#   separate --scratch-path (.build-appstage/<id>) so the APPSTAGE capture
#   binary, built into that dir, gets the same patched macOS slice.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-$ROOT/.build}"
MAC_SLICE="$SCRATCH/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework"
IOS_SLICE="$SCRATCH/artifacts/webrtc/WebRTC/WebRTC.xcframework/ios-arm64/WebRTC.framework"

if [ ! -d "$MAC_SLICE" ]; then
    echo "patch-webrtc-macos: no macOS framework slice — run \`swift package resolve\` first." >&2
    exit 0
fi
if [ ! -d "$IOS_SLICE" ]; then
    echo "patch-webrtc-macos: no iOS slice to copy headers from." >&2
    exit 1
fi

# The Headers symlink in the framework root points at Versions/A/Headers.
MAC_HEADERS="$MAC_SLICE/Versions/A/Headers"
IOS_HEADERS="$IOS_SLICE/Headers"

# Idempotency marker — the patched umbrella ends with RTCMTLNSVideoView.h,
# which the stock stasel umbrella never references on macOS.
if [ -f "$MAC_HEADERS/RTCMTLNSVideoView.h" ] && \
   grep -q "RTCMTLNSVideoView.h" "$MAC_HEADERS/WebRTC.h" 2>/dev/null; then
    exit 0
fi

echo "patch-webrtc-macos: copying $(ls "$IOS_HEADERS" | wc -l | tr -d ' ') headers from iOS slice..."
cp "$IOS_HEADERS"/*.h "$MAC_HEADERS/"

# Rewrite the umbrella header to drop iOS-only entries. The list below is
# every header in the iOS umbrella that imports UIKit, GLKit, or types
# only defined on iOS (UIDevice, AVAudioSession, …).
IOS_ONLY=(
    RTCEAGLVideoView.h
    RTCMTLVideoView.h
    RTCCameraPreviewView.h
    UIDevice+RTCDevice.h
    RTCAudioSession.h
    RTCAudioSessionConfiguration.h
)

UMBRELLA="$MAC_HEADERS/WebRTC.h"
TMP="$UMBRELLA.tmp"
cp "$IOS_HEADERS/WebRTC.h" "$TMP"
for h in "${IOS_ONLY[@]}"; do
    # Strip the line ` #import <WebRTC/$h>` if present.
    sed -i.bak "\#<WebRTC/$h>#d" "$TMP"
    rm -f "$TMP.bak"
done

# Add the macOS-only Metal renderer.
cat >> "$TMP" <<'EOF'
#import <WebRTC/RTCMTLNSVideoView.h>
EOF
mv "$TMP" "$UMBRELLA"

# Drop the macOS-specific header. Declared by hand because stasel/WebRTC
# doesn't ship it, even though the binary exports the class.
cat > "$MAC_HEADERS/RTCMTLNSVideoView.h" <<'EOF'
/*
 *  Synthesised header for the macOS Metal renderer.
 *
 *  stasel/WebRTC's macOS slice ships the compiled class but no header.
 *  Class signature lifted from the public WebRTC source.
 */

#import <AppKit/AppKit.h>
#import <WebRTC/RTCMacros.h>
#import <WebRTC/RTCVideoRenderer.h>

NS_ASSUME_NONNULL_BEGIN

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCMTLNSVideoView) : NSView <RTC_OBJC_TYPE(RTCVideoRenderer)>

@property(nonatomic, weak, nullable) id<RTC_OBJC_TYPE(RTCVideoViewDelegate)> delegate;

- (instancetype)initWithFrame:(NSRect)frameRect;

@end

NS_ASSUME_NONNULL_END
EOF

echo "patch-webrtc-macos: patched ($(ls "$MAC_HEADERS" | wc -l | tr -d ' ') headers)."
