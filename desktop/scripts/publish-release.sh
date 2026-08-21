#!/usr/bin/env bash
# Publish Desktop releases with OSS as the canonical store. A normal publish
# replaces provisional version artifacts until an immutable manifest seals
# them, deploys the exact Browser archive to openseek-api for same-origin
# `/console/`, and replaces latest.json last.
#
#   scripts/publish-release.sh publish [vX.Y.Z]  publish the checkout's artifacts
#   scripts/publish-release.sh rollback vX.Y.Z   republish an immutable manifest
#   scripts/publish-release.sh status            print the OSS-owned latest.json
#
# Requires OPENSEEK_RELEASES_ORIGIN, OPENSEEK_OSS_BUCKET,
# OPENSEEK_OSS_REGION, OPENSEEK_OSS_PREFIX, OPENSEEK_API_ORIGIN, and
# OPENSEEK_DEPLOY_TOKEN, plus ossutil 2.x credentials.
set -euo pipefail

desktop_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$desktop_dir/moon.mod")"
if [[ -z "$version" ]]; then
  echo "could not read version from moon.mod" >&2
  exit 1
fi

case "${1:-}" in
  publish)
    publish_version="${2:-v$version}"
    if [[ "$publish_version" != "v$version" ]]; then
      echo "publish version $publish_version does not match checkout version v$version" >&2
      echo "use rollback for an already-published version" >&2
      exit 64
    fi
    releases_origin="${OPENSEEK_RELEASES_ORIGIN:?set OPENSEEK_RELEASES_ORIGIN}"
    oss_bucket="${OPENSEEK_OSS_BUCKET:?set OPENSEEK_OSS_BUCKET}"
    oss_region="${OPENSEEK_OSS_REGION:?set OPENSEEK_OSS_REGION}"
    oss_prefix="${OPENSEEK_OSS_PREFIX:?set OPENSEEK_OSS_PREFIX}"
    api_origin="${OPENSEEK_API_ORIGIN:?set OPENSEEK_API_ORIGIN}"
    deploy_token="${OPENSEEK_DEPLOY_TOKEN:?set OPENSEEK_DEPLOY_TOKEN}"
    releases_origin="${releases_origin%/}"
    oss_prefix="${oss_prefix#/}"
    oss_prefix="${oss_prefix%/}"
    api_origin="${api_origin%/}"

    artifacts=(
      "$desktop_dir/dist/SeekMoon.app.zip"
      "$desktop_dir/dist/SeekMoon.dmg"
      "$desktop_dir/dist/SeekMoon.browser.tar.gz"
    )
    platforms=("macos-arm64" "macos-arm64-dmg" "browser")
    content_types=("application/zip" "application/x-apple-diskimage" "application/gzip")
    manifest_path="$desktop_dir/dist/latest.json"
    version_manifest_key="$oss_prefix/$publish_version/manifest.json"
    version_manifest_destination="oss://$oss_bucket/$version_manifest_key"
    version_manifest_url="$releases_origin/$publish_version/manifest.json"
    artifact_urls=()
    artifact_shas=()
    browser_staged=false

    # The immutable version manifest is the commit marker. A failed HEAD must
    # never be mistaken for an open version: only OSS's explicit NoSuchKey
    # response permits this run to replace provisional artifacts.
    manifest_head_status=0
    manifest_head="$(
      ossutil api head-object \
        --region "$oss_region" \
        --bucket "$oss_bucket" \
        --key "$version_manifest_key" \
        --output-format json 2>&1
    )" || manifest_head_status=$?
    if ((manifest_head_status == 0)); then
      echo "$publish_version is sealed; reusing its OSS manifest and artifacts"
      ossutil cp --force --region "$oss_region" \
        "$version_manifest_destination" "$manifest_path"
      jq -e --arg version "$version" '
        .version == $version and
        (.platforms["macos-arm64"].url | type == "string") and
        (.platforms["macos-arm64"].sha256 | type == "string") and
        (.platforms["macos-arm64-dmg"].url | type == "string") and
        (.platforms["macos-arm64-dmg"].sha256 | type == "string") and
        (.platforms.browser.url | type == "string") and
        (.platforms.browser.sha256 | type == "string")
      ' "$manifest_path" >/dev/null
      artifact_urls=(
        "$(jq -er '.platforms["macos-arm64"].url' "$manifest_path")"
        "$(jq -er '.platforms["macos-arm64-dmg"].url' "$manifest_path")"
        "$(jq -er '.platforms.browser.url' "$manifest_path")"
      )
      artifact_shas=(
        "$(jq -er '.platforms["macos-arm64"].sha256' "$manifest_path")"
        "$(jq -er '.platforms["macos-arm64-dmg"].sha256' "$manifest_path")"
        "$(jq -er '.platforms.browser.sha256' "$manifest_path")"
      )

      # The workflow rebuilt before discovering this sealed retry. Replace
      # those nondeterministic bytes with the exact objects the manifest owns,
      # so later artifact upload and verification use the published release.
      for index in 0 1 2; do
        artifact="${artifacts[$index]}"
        release_name="$(basename "$artifact")"
        oss_destination="oss://$oss_bucket/$oss_prefix/$publish_version/$release_name"
        ossutil cp --force --region "$oss_region" "$oss_destination" "$artifact"
        local_sha="$(shasum -a 256 "$artifact" | cut -d' ' -f1)"
        if [[ "$local_sha" != "${artifact_shas[$index]}" ]]; then
          echo "sealed $release_name does not match $version_manifest_url" >&2
          exit 1
        fi
      done
      COPYFILE_DISABLE=1 tar -xzf "${artifacts[2]}" -C "$desktop_dir/dist"
    elif [[ "$manifest_head" == *"Http Status Code: 404."* && \
      "$manifest_head" == *"Error Code: NoSuchKey."* ]]; then
      echo "$publish_version is open; uploading replaceable artifacts"
      for index in 0 1 2; do
        artifact="${artifacts[$index]}"
        platform="${platforms[$index]}"
        content_type="${content_types[$index]}"
        if [[ ! -f "$artifact" ]]; then
          echo "artifact not found: $artifact" >&2
          exit 1
        fi
        release_name="$(basename "$artifact")"
        oss_destination="oss://$oss_bucket/$oss_prefix/$publish_version/$release_name"
        public_url="$releases_origin/$publish_version/$release_name"
        local_sha="$(shasum -a 256 "$artifact" | cut -d' ' -f1)"
        local_size="$(wc -c < "$artifact" | tr -d '[:space:]')"

        # Until manifest.json exists these objects are provisional. Retrying a
        # partial release must replace nondeterministic rebuilds instead of
        # preserving bytes that no immutable manifest committed.
        echo "uploading $artifact"
        echo "       to $oss_destination"
        ossutil cp --force --region "$oss_region" \
          --content-type "$content_type" \
          --cache-control "public, max-age=31536000, immutable" \
          --metadata "sha256=$local_sha" \
          "$artifact" "$oss_destination"

        headers="$(curl -fsSI --retry 3 "$public_url" | tr -d '\r')"
        served_size="$(awk 'tolower($1) == "content-length:" { print $2; exit }' <<< "$headers")"
        served_sha="$(awk 'tolower($1) == "x-oss-meta-sha256:" { print $2; exit }' <<< "$headers")"
        served_crc64="$(awk 'tolower($1) == "x-oss-hash-crc64ecma:" { print $2; exit }' <<< "$headers")"
        if [[ "$served_size" != "$local_size" || \
          "$served_sha" != "$local_sha" || \
          -z "$served_crc64" ]]; then
          echo "OSS verification failed for $platform at $public_url" >&2
          exit 1
        fi
        artifact_urls+=("$public_url")
        artifact_shas+=("$local_sha")
        echo "$platform verified: $public_url"
      done

      # Stage Browser before sealing the manifest. It remains replaceable in
      # the API until the later publish request selects this version.
      browser_archive="${artifacts[2]}"
      browser_upload_url="$api_origin/desktop/releases/$publish_version/SeekMoon.browser.tar.gz?platform=browser"
      response="$(curl -sS --fail-with-body -T "$browser_archive" \
        -H "Authorization: Bearer $deploy_token" "$browser_upload_url")"
      response_sha="$(jq -er '.sha256' <<< "$response")"
      if [[ "$response_sha" != "${artifact_shas[2]}" ]]; then
        echo "DIGEST MISMATCH: API recorded $response_sha for Browser" >&2
        exit 1
      fi
      browser_staged=true

      jq -n \
        --arg version "$version" \
        --arg archive_url "${artifact_urls[0]}" \
        --arg archive_sha "${artifact_shas[0]}" \
        --arg dmg_url "${artifact_urls[1]}" \
        --arg dmg_sha "${artifact_shas[1]}" \
        --arg browser_url "${artifact_urls[2]}" \
        --arg browser_sha "${artifact_shas[2]}" \
        '{
          version: $version,
          url: "https://github.com/moonbitlang/openseek/releases/latest",
          platforms: {
            "macos-arm64": {url: $archive_url, sha256: $archive_sha},
            "macos-arm64-dmg": {url: $dmg_url, sha256: $dmg_sha},
            browser: {url: $browser_url, sha256: $browser_sha}
          }
        }' > "$manifest_path"

      manifest_sha="$(shasum -a 256 "$manifest_path" | cut -d' ' -f1)"
      ossutil api put-object \
        --region "$oss_region" \
        --bucket "$oss_bucket" \
        --key "$version_manifest_key" \
        --body "file://$manifest_path" \
        --content-type "application/json" \
        --cache-control "public, max-age=31536000, immutable" \
        --metadata "sha256=$manifest_sha" \
        --forbid-overwrite true
      echo "$publish_version sealed at $version_manifest_url"
    else
      printf '%s\n' "$manifest_head" >&2
      exit "$manifest_head_status"
    fi

    manifest_sha="$(shasum -a 256 "$manifest_path" | cut -d' ' -f1)"
    manifest_size="$(wc -c < "$manifest_path" | tr -d '[:space:]')"
    headers="$(curl -fsSI --retry 3 "$version_manifest_url" | tr -d '\r')"
    served_size="$(awk 'tolower($1) == "content-length:" { print $2; exit }' <<< "$headers")"
    served_sha="$(awk 'tolower($1) == "x-oss-meta-sha256:" { print $2; exit }' <<< "$headers")"
    if [[ "$served_size" != "$manifest_size" || "$served_sha" != "$manifest_sha" ]]; then
      echo "version manifest verification failed at $version_manifest_url" >&2
      exit 1
    fi

    # Browser remains on the API origin because its session cookies, HTTP API,
    # and WebSocket routes are same-origin. A sealed retry stages the exact OSS
    # archive; a retry after selection skips straight to latest.json.
    browser_current="$(curl -fsSL "$api_origin/browser/releases/current.json" 2>/dev/null || true)"
    if ! jq -e --arg version "$version" '.version == $version' \
      <<< "$browser_current" >/dev/null 2>&1; then
      if [[ "$browser_staged" != true ]]; then
        browser_archive="${artifacts[2]}"
        browser_upload_url="$api_origin/desktop/releases/$publish_version/SeekMoon.browser.tar.gz?platform=browser"
        response="$(curl -sS --fail-with-body -T "$browser_archive" \
          -H "Authorization: Bearer $deploy_token" "$browser_upload_url")"
        response_sha="$(jq -er '.sha256' <<< "$response")"
        if [[ "$response_sha" != "${artifact_shas[2]}" ]]; then
          echo "DIGEST MISMATCH: API recorded $response_sha for Browser" >&2
          exit 1
        fi
      fi
      curl -sS --fail-with-body -X POST \
        -H "Authorization: Bearer $deploy_token" \
        "$api_origin/browser/releases/$publish_version/publish"
      echo
    fi

    # This small object is the only mutable release object and therefore the
    # publication point. OSS replaces one object atomically.
    latest_destination="oss://$oss_bucket/$oss_prefix/latest.json"
    ossutil cp --force --region "$oss_region" \
      --content-type "application/json" \
      --cache-control "no-cache" \
      --metadata "sha256=$manifest_sha" \
      "$manifest_path" "$latest_destination"
    ;;

  rollback)
    rollback_version="${2:?usage: publish-release.sh rollback vX.Y.Z}"
    if [[ ! "$rollback_version" =~ ^v[[:alnum:]][[:alnum:]_.-]*$ ]]; then
      echo "invalid rollback version: $rollback_version" >&2
      exit 64
    fi
    releases_origin="${OPENSEEK_RELEASES_ORIGIN:?set OPENSEEK_RELEASES_ORIGIN}"
    oss_bucket="${OPENSEEK_OSS_BUCKET:?set OPENSEEK_OSS_BUCKET}"
    oss_region="${OPENSEEK_OSS_REGION:?set OPENSEEK_OSS_REGION}"
    oss_prefix="${OPENSEEK_OSS_PREFIX:?set OPENSEEK_OSS_PREFIX}"
    api_origin="${OPENSEEK_API_ORIGIN:?set OPENSEEK_API_ORIGIN}"
    deploy_token="${OPENSEEK_DEPLOY_TOKEN:?set OPENSEEK_DEPLOY_TOKEN}"
    releases_origin="${releases_origin%/}"
    oss_prefix="${oss_prefix#/}"
    oss_prefix="${oss_prefix%/}"
    api_origin="${api_origin%/}"
    manifest_path="$desktop_dir/dist/latest.json"
    curl -fsSL --retry 3 \
      "$releases_origin/$rollback_version/manifest.json" \
      -o "$manifest_path"
    jq -e --arg version "${rollback_version#v}" '.version == $version' \
      "$manifest_path" >/dev/null
    manifest_sha="$(shasum -a 256 "$manifest_path" | cut -d' ' -f1)"

    # Keep the same-origin Browser console on the same release as the Desktop
    # pointer. The endpoint reselects an already-extracted immutable version.
    curl -sS --fail-with-body -X POST \
      -H "Authorization: Bearer $deploy_token" \
      "$api_origin/browser/releases/$rollback_version/publish"
    echo

    ossutil cp --force --region "$oss_region" \
      --content-type "application/json" \
      --cache-control "no-cache" \
      --metadata "sha256=$manifest_sha" \
      "$manifest_path" "oss://$oss_bucket/$oss_prefix/latest.json"
    ;;

  status)
    releases_origin="${OPENSEEK_RELEASES_ORIGIN:?set OPENSEEK_RELEASES_ORIGIN}"
    curl -fsSL "${releases_origin%/}/latest.json"
    echo
    exit 0
    ;;

  *)
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 64
    ;;
esac

# Publish and rollback both finish by observing the public CDN response. This
# catches a stale or misconfigured mutable cache without downloading artifacts.
expected_version="${publish_version:-${rollback_version#v}}"
expected_version="${expected_version#v}"
published=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if published="$(curl -fsSL "${releases_origin%/}/latest.json")" &&
    jq -e --arg version "$expected_version" '.version == $version' \
      <<< "$published" >/dev/null; then
    break
  fi
  if [[ "$attempt" == 10 ]]; then
    echo "latest.json did not converge to $expected_version" >&2
    exit 1
  fi
  sleep 2
done
latest_headers="$(curl -fsSI "${releases_origin%/}/latest.json" | tr -d '\r')"
latest_sha="$(awk 'tolower($1) == "x-oss-meta-sha256:" { print $2; exit }' <<< "$latest_headers")"
if [[ "$latest_sha" != "$manifest_sha" ]]; then
  echo "latest.json metadata does not match the published manifest" >&2
  exit 1
fi
echo "$published"
