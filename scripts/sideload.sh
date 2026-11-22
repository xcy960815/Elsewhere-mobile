#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage / 用法: scripts/sideload.sh [--mode free|full] [--bundle-id ID] [--team TEAM] ACTION...
  --check          Check tools, device slice, signing identities, iOS devices and local profiles.
                   检查构建环境、证书、已连接设备及本地描述文件。默认操作。
  --ipa            Build an unsigned arm64 IPA without an Apple login / 打包未签名 IPA。
  --install        Build and install on a paired iPhone/iPad / 构建并安装到已配对真机。
  --test           Run the full Debug XCTest suite on a paired device / 在已配对真机上运行全量 Debug 单元测试。
                   Use local profiles when available / 优先复用本地描述文件。
  --device UDID    Choose a device for --check, --install or --test / 指定检查、安装或测试的真机 UDID。
  --open           Open the generated project in Xcode / 用 Xcode 打开工程。
  --mode free      Personal Team, host only (default) / 免费版，仅宿主，默认。
  --mode full      Host, tunnel, widget and share extension / 完整版，含三个扩展。
  --bundle-id ID   Save bundle ID locally / 写入本地签名配置。
  --team TEAM      Save the 10-character development team ID / 写入十位 Team ID。
  --help           Show usage / 显示帮助。
HELP
}
die() { echo "$*" >&2; exit 1; }
need_value() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 缺少参数 / missing value"; }

mode=free
team=
bundle_id=
device=
check=0
ipa=0
install_app=0
run_tests=0
open_project=0
while (($#)); do
    case $1 in
        --mode) need_value "$@"; mode=$2; shift ;;
        --team) need_value "$@"; team=$2; shift ;;
        --bundle-id) need_value "$@"; bundle_id=$2; shift ;;
        --device) need_value "$@"; device=$2; shift ;;
        --check) check=1 ;;
        --ipa) ipa=1 ;;
        --install) install_app=1 ;;
        --test) run_tests=1 ;;
        --open) open_project=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "未知参数 / unknown option: $1" ;;
    esac
    shift
done
case $mode in
    free) scheme=ElsewhereMobileFree ;;
    full) scheme=ElsewhereMobile ;;
    *) die "--mode 请选择 / must be free|full" ;;
esac
needs_device=$((install_app || run_tests))
if ((!check && !ipa && !needs_device && !open_project)); then check=1; fi
[[ -z $bundle_id || $bundle_id =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "Bundle ID 格式无效 / invalid bundle ID"
[[ -z $team || $team =~ ^[A-Z0-9]{10}$ ]] || die "Team ID 格式无效 / invalid Team ID"
[[ -z $device || $check == 1 || $needs_device == 1 ]] || die "--device 需配合 / requires --check, --install or --test"

cd "$(dirname "$0")/.."
root=$PWD
out="$root/build/sideload"
stage="$out/project"
core="$root/build/ElsewhereCore.xcframework"
command -v python3 >/dev/null || die "缺少 Python 3 / install Python 3"
command -v xcodegen >/dev/null || die "缺少 XcodeGen / install with: brew install xcodegen"
xcrun --find xcodebuild >/dev/null || die "请在 xcode-select 中选择 Xcode / select a full Xcode installation"
if ((install_app || check)); then
    xcrun --find devicectl >/dev/null || die "缺少 devicectl / select Xcode 16 or later"
fi
python3 - "$core" <<'PY'
import pathlib, plistlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
if (root / "Info.plist").is_file():
    with (root / "Info.plist").open("rb") as stream:
        libraries = plistlib.load(stream)["AvailableLibraries"]
    for lib in libraries:
        if (lib["SupportedPlatform"] == "ios" and not lib.get("SupportedPlatformVariant")
                and "arm64" in lib["SupportedArchitectures"]):
            path = root / lib["LibraryIdentifier"] / lib["LibraryPath"]
            if path.is_file() and subprocess.run(["xcrun", "lipo", str(path), "-verify_arch", "arm64"]).returncode == 0:
                print("XcodeGen ✓   XCFramework ios-arm64 ✓")
                break
    else:
        sys.exit("缺少真机切片 / missing device library: scripts/build-rust-ios.sh --device")
else:
    sys.exit("缺少 XCFramework / build it first: scripts/build-rust-ios.sh --device")
PY

mkdir -p "$stage/build"
exec 9>"$out/sideload.lock"
python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
scratch=$(mktemp -d "$out/.work.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

# Keep generated plists, project files and catalog build products in the staging tree.
for dir in App Domain Engine Services DesignSystem Features Intents Resources Widgets TunnelExtension PairingImportExtension Tests; do
    mkdir -p "$stage/$dir"
    rsync -a --delete "$root/$dir/" "$stage/$dir/"
done
cp project.yml "$stage/project.yml"
[[ -L $stage/build/ElsewhereCore.xcframework ]] || ln -s "$core" "$stage/build/ElsewhereCore.xcframework"
[[ -L $stage/Config ]] || ln -s "$root/Config" "$stage/Config"

save_overrides() {
    python3 - "$root/Config/Signing.local.xcconfig" "$scratch" "$mode" "$1" "$2" <<'PY'
import os, pathlib, re, sys
path, scratch = map(pathlib.Path, sys.argv[1:3])
mode, bundle, team = sys.argv[3:]
overrides = {}
if bundle:
    overrides["APP_BUNDLE_ID"] = bundle
    if mode == "free":
        overrides["FREE_APP_BUNDLE_ID"] = bundle
if team:
    overrides["DEVELOPMENT_TEAM"] = team
if overrides:
    previous = path.read_text() if path.exists() else ""
    lines = [line for line in previous.splitlines()
             if not any(re.match(r"^\s*" + key + r"\s*=", line) for key in overrides)]
    lines.extend(f"{key} = {value}" for key, value in overrides.items())
    updated = "\n".join(lines) + "\n"
    if updated != previous:
        temporary = scratch / "Signing.local.xcconfig"
        temporary.write_text(updated)
        os.replace(temporary, path)
PY
}
save_overrides "$bundle_id" "$team"
(cd "$stage" && xcodegen generate)
project="$stage/ElsewhereMobile.xcodeproj"
build_args=(-project "$project" -scheme "$scheme" -sdk iphoneos)
if ((check || needs_device)); then
    settings_config=Release
    if ((run_tests)); then settings_config=Debug; fi
    xcodebuild "${build_args[@]}" -configuration "$settings_config" -derivedDataPath "$out/settings" -destination 'generic/platform=iOS' \
        -showBuildSettings -json > "$scratch/settings.json"
    xcrun xcdevice list > "$scratch/devices.json"
    # Match certificate fingerprints, not a name or the personal ID in its CN.
    python3 - "$scratch" "$scheme" "$device" "$needs_device" <<'PY' > "$scratch/selection"
import base64, datetime, fnmatch, hashlib, json, pathlib, plistlib, re, subprocess, sys
scratch = pathlib.Path(sys.argv[1])
scheme, requested, needs_device = sys.argv[2:]
def report(message):
    print(message, file=sys.stderr)
def run(*args, **kwargs):
    return subprocess.run(args, stdout=subprocess.PIPE, **kwargs)

settings = next(t["buildSettings"] for t in json.loads((scratch / "settings.json").read_text()) if t["target"] == scheme)
bundle, team = settings["PRODUCT_BUNDLE_IDENTIFIER"], settings.get("DEVELOPMENT_TEAM", "")
report(f"Scheme: {scheme}   Bundle ID: {bundle}")
identities = run("security", "find-identity", "-v", "-p", "codesigning", check=True).stdout
valid = set(re.findall(rb'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"Apple Development:', identities, re.M))
certificates = run("security", "find-certificate", "-a", "-p", "-c", "Apple Development")
if certificates.returncode not in (0, 44):
    sys.exit("无法读取钥匙串证书 / could not read development certificates")
teams = {}
for pem in re.findall(rb"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", certificates.stdout, re.S):
    der = base64.b64decode(pem)
    fingerprint = hashlib.sha1(der).hexdigest().upper()
    if fingerprint.encode() not in valid:
        continue
    subject = run("openssl", "x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "RFC2253",
                  input=der, check=True).stdout.decode()
    match = re.search(r"(?:^|[,= ])OU=([A-Z0-9]{10})(?:,|$)", subject.strip())
    if match:
        teams[fingerprint] = match[1]
        report(f"Apple Development: {fingerprint}   Team ID: {match[1]}")
if not teams:
    report("未发现可用开发证书和私钥 / no usable Apple Development identity")
auto = ""
if not team and len(valid) == len(teams) == 1:
    auto = team = next(iter(teams.values()))
    report(f"已从唯一开发证书推导 Team ID / detected signing team: {team}")

devices = {}
for device in json.loads((scratch / "devices.json").read_text()):
    if device["simulator"] or device["platform"] != "com.apple.platform.iphoneos":
        continue
    name, udid = device["name"], device["identifier"]
    if device["available"]:
        devices[udid] = name
        report(f"Device: {name}   UDID: {udid}")
    else:
        reason = device.get("error", {}).get("description", "unavailable")
        report(f"不可用 / unavailable: {name}   {udid}   {reason}")
if not devices:
    report("无可用真机 / no available iPhone or iPad")
if requested and requested not in devices:
    sys.exit("指定的 UDID 未连接或不可用 / selected device unavailable")
selected = requested or (next(iter(devices)) if len(devices) == 1 else "")
if needs_device == "1" and not selected:
    sys.exit("连接、解锁并信任设备。多台设备请指定 --device UDID / select one available device")
if needs_device == "1" and not team:
    sys.exit("请传入 --team TEAMID 或配置 DEVELOPMENT_TEAM / select a signing team")

requirements = {bundle: ([], False)}
if scheme == "ElsewhereMobile":
    snapshot, inbox = settings["SNAPSHOT_APP_GROUP"], settings["IMPORT_APP_GROUP"]
    requirements = {bundle: ([snapshot, inbox], True), bundle + ".widgets": ([snapshot], False),
                    bundle + ".pairingimport": ([inbox], False), bundle + ".tunnel": ([], True)}
profiles = []
library = pathlib.Path.home() / "Library"
for folder in ("Developer/Xcode/UserData/Provisioning Profiles", "MobileDevice/Provisioning Profiles"):
    for path in (library / folder).glob("*.mobileprovision"):
        decoded = run("security", "cms", "-D", "-i", str(path), stderr=subprocess.DEVNULL)
        if decoded.returncode:
            report(f"无法解码描述文件 / unreadable profile: {path.name}")
            continue
        profile = plistlib.loads(decoded.stdout)
        if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            continue
        if team not in profile.get("TeamIdentifier", []) or "iOS" not in profile.get("Platform", ["iOS"]):
            continue
        if any(teams.get(hashlib.sha1(cert).hexdigest().upper()) == team for cert in profile["DeveloperCertificates"]):
            profiles.append(profile)

def matches(profile, udid, bundle_id, groups, tunnel):
    ent = profile["Entitlements"]
    grants = ent.get("com.apple.security.application-groups", [])
    ne = ent.get("com.apple.developer.networking.networkextension", [])
    app_id = ent.get("application-identifier", "")
    return (udid in profile.get("ProvisionedDevices", []) and ent.get("get-task-allow") is True
            and any(fnmatch.fnmatchcase(prefix + "." + bundle_id, app_id) for prefix in profile["ApplicationIdentifierPrefix"])
            and all(any(fnmatch.fnmatchcase(group, grant) for grant in grants) for group in groups)
            and (not tunnel or "packet-tunnel-provider" in ne or "*" in ne))

offline = False
for udid in ([selected] if selected else devices):
    complete = True
    for bundle_id, (groups, tunnel) in requirements.items():
        profile = next((p for p in profiles if matches(p, udid, bundle_id, groups, tunnel)), None)
        label = profile["Name"] if profile else "无匹配描述文件 / no matching local profile"
        report(f"{udid}   {bundle_id}: {label}")
        complete = complete and profile is not None
    if udid == selected:
        offline = complete
print("|".join((auto, selected, str(int(offline)))))
PY
    IFS='|' read -r auto_team selected_device offline < "$scratch/selection"
    if [[ -n $auto_team ]]; then save_overrides "" "$auto_team"; fi
fi
if ((ipa)); then
    products="$out/products/$mode-unsigned"
    xcodebuild "${build_args[@]}" -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$out/derived/$mode-unsigned" \
        ARCHS=arm64 CODE_SIGNING_ALLOWED=NO "CONFIGURATION_BUILD_DIR=$products" build
    mkdir "$scratch/Payload"
    ditto "$products/$scheme.app" "$scratch/Payload/$scheme.app"
    archive="ElsewhereMobile-$mode-unsigned.ipa"
    (cd "$scratch" && COPYFILE_DISABLE=1 /usr/bin/zip -qry "$archive" Payload)
    mv -f "$scratch/$archive" "$out/$archive"
    echo "未签名 IPA / unsigned IPA: $out/$archive"
fi
if ((install_app)); then
    products="$out/products/$mode-signed"
    signed_build() {
        xcodebuild "${build_args[@]}" -configuration Release -destination "platform=iOS,id=$selected_device" \
            -derivedDataPath "$out/derived/$mode-signed" ARCHS=arm64 "CONFIGURATION_BUILD_DIR=$products" "$@" build \
            2>&1 | tee "$scratch/install.log"
    }
    online=1
    if [[ $offline == 1 ]]; then
        echo "使用本地描述文件 / building with local profiles"
        if signed_build; then online=0
        elif ! grep -Eiq 'provision|signing certificate|signing identit|entitlement' "$scratch/install.log"; then exit 1
        fi
    fi
    if ((online)); then
        echo "请求 Xcode 自动签名 / requesting automatic provisioning"
        if ! signed_build -allowProvisioningUpdates -allowProvisioningDeviceRegistration; then
            if grep -Eiq -- '-1001|timed out' "$scratch/install.log"; then
                echo "Apple 服务超时（-1001）：检查代理、DNS、网络和 Xcode 账号登录状态后重试。 / Check connectivity to Apple." >&2
            fi
            die "检查 Xcode › Settings › Accounts、Team ID 和 Bundle ID 是否可用。免费个人账号请选择 --mode free；完整版需要 Network Extension 和 App Groups 权限。 / Check the team, bundle IDs and capabilities."
        fi
    fi
    xcrun devicectl device install app --device "$selected_device" "$products/$scheme.app"
fi
if ((run_tests)); then
    test_args=(-configuration Debug -destination "platform=iOS,id=$selected_device" -derivedDataPath "$out/derived/$mode-tests")
    # Hosted unit tests run inside the signed app and use its provisioning profile.
    if [[ $offline == 1 ]] || ((install_app)); then
        echo "使用本地描述文件运行测试 / testing with local profiles"
    else
        echo "缺少本地描述文件，交由 Xcode 自动签名 / requesting automatic provisioning for tests"
        test_args+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
    fi
    xcodebuild "${build_args[@]}" "${test_args[@]}" test
fi
if ((open_project)); then
    echo "请在 Xcode 中选择 Scheme / select scheme: $scheme"
    open "$project"
fi
