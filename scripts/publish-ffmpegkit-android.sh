#!/bin/bash
#
# publish-ffmpegkit-android.sh [local|central]
#
# Publishes android/libs/ffmpegkit.aar (build it with build-ffmpeg-android.sh) as
# dev.mediacache:ffmpegkit-vp9:<version>. Version defaults to 6.0.0; override with
# FFMPEGKIT_VP9_VERSION.
#
#   local    publishToMavenLocal (~/.m2), unsigned unless a key is set. The default.
#   central  signs, bundles and uploads to the Maven Central Portal. Needs:
#              ORG_GRADLE_PROJECT_mavenCentralUsername / …Password   Central Portal user token
#              ORG_GRADLE_PROJECT_signingInMemoryKey                 armored secret key
#              ORG_GRADLE_PROJECT_signingInMemoryKeyPassword
#              ORG_GRADLE_PROJECT_signingInMemoryKeyId               optional
#            The deployment waits in the portal for you to press Publish, unless
#            PUBLISHING_TYPE=AUTOMATIC.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRADLE_DIR="$SCRIPT_DIR/maven"
MODE="${1:-local}"
VERSION="${FFMPEGKIT_VP9_VERSION:-6.0.0}"
GRADLE=("$GRADLE_DIR/gradlew" -p "$GRADLE_DIR" -q "-PffmpegkitVp9Version=$VERSION")

case "$MODE" in
    local)
        "${GRADLE[@]}" publishToMavenLocal
        echo "✅ dev.mediacache:ffmpegkit-vp9:$VERSION in ~/.m2/repository"
        ;;
    central)
        for var in ORG_GRADLE_PROJECT_mavenCentralUsername ORG_GRADLE_PROJECT_mavenCentralPassword \
                   ORG_GRADLE_PROJECT_signingInMemoryKey ORG_GRADLE_PROJECT_signingInMemoryKeyPassword; do
            if [ -z "${!var:-}" ]; then
                echo "❌ $var is not set"
                exit 1
            fi
        done

        STAGING="$GRADLE_DIR/build/staging-repo"
        rm -rf "$STAGING"
        "${GRADLE[@]}" publishMavenPublicationToStagingRepository

        VERSION_DIR="dev/mediacache/ffmpegkit-vp9/$VERSION"
        if ! ls "$STAGING/$VERSION_DIR"/*.aar.asc > /dev/null 2>&1; then
            echo "❌ Artifacts were not signed"
            exit 1
        fi

        BUNDLE="$GRADLE_DIR/build/ffmpegkit-vp9-$VERSION-bundle.zip"
        rm -f "$BUNDLE"
        (cd "$STAGING" && zip -qr "$BUNDLE" "$VERSION_DIR")
        echo "📦 $BUNDLE"
        unzip -l "$BUNDLE" | awk 'NR > 3 { print "   " $4 }' | sed '/^   $/d'

        TOKEN="$(printf '%s:%s' "$ORG_GRADLE_PROJECT_mavenCentralUsername" "$ORG_GRADLE_PROJECT_mavenCentralPassword" | base64 | tr -d "\n")"
        DEPLOYMENT_ID="$(curl --fail-with-body -sS \
            -H "Authorization: Bearer $TOKEN" \
            -F "bundle=@$BUNDLE" \
            "https://central.sonatype.com/api/v1/publisher/upload?name=ffmpegkit-vp9-$VERSION&publishingType=${PUBLISHING_TYPE:-USER_MANAGED}")"
        echo "⬆️  Uploaded, deployment $DEPLOYMENT_ID"
        echo "   Status: curl -sS -X POST -H 'Authorization: Bearer …' 'https://central.sonatype.com/api/v1/publisher/status?id=$DEPLOYMENT_ID'"
        echo "   Or watch https://central.sonatype.com/publishing/deployments"
        ;;
    *)
        echo "Usage: $0 [local|central]"
        exit 1
        ;;
esac
