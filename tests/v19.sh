#!/bin/bash
set -Eeuo pipefail
umask 077

report_failure() {
    local status=$1 line=$2 command=$3
    printf 'ASP.NET v19 test failed: status=%s line=%s unit=%s command=%s\n' \
        "$status" "$line" "${unit:-none}" "$command" >&2
    exit "$status"
}
trap 'report_failure "$?" "$LINENO" "$BASH_COMMAND"' ERR

result=${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}
db_password=${TKL_TEST_DB_PASS:?TKL_TEST_DB_PASS is required}
source_file=/usr/local/share/turnkey-aspnetcore/source
page=$(mktemp /tmp/aspnetcore-page.XXXXXXXX)
update=$(mktemp /tmp/aspnetcore-update.XXXXXXXX)

cleanup() {
    find "$page" "$update" -maxdepth 0 -delete
}
trap cleanup EXIT

for unit in nginx.service mariadb.service aspnetcore.service; do
    systemctl --quiet is-active "$unit"
    systemctl --quiet is-enabled "$unit"
done
nginx -t
grep -Fxq 'VERSION_CODENAME=trixie' /etc/os-release
grep -Eq '^turnkey-asp-net-core-19\.0' /etc/turnkey_version

# shellcheck disable=SC1090
. "$source_file"
test "$dotnet_channel" = 10.0
test "$ef_version" = 9.0.19
test "$mysql_ef_version" = 9.0.0
test "$microsoft_key_fingerprint" = AA86F75E427A19DD33346403EE4D7792F748182B
test "$microsoft_key_url" = https://packages.microsoft.com/keys/microsoft-2025.asc
test "$(gpg --batch --show-keys --with-colons /usr/share/keyrings/microsoft.gpg |
    awk -F: '$1 == "fpr" {print $10; exit}')" = "$microsoft_key_fingerprint"
grep -Fxq 'deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/13/prod trixie main' \
    /etc/apt/sources.list.d/microsoft.list
test "$(dotnet --version)" = "$sdk_version"
sha256sum /var/www/aspnetcore-src/packages.lock.json |
    grep -Fq "$lock_sha256"
lock=/var/www/aspnetcore-src/packages.lock.json
jq -e --arg package Microsoft.EntityFrameworkCore.Relational \
    --arg version "$ef_version" \
    '.dependencies["net10.0"][$package] |
        .type == "Direct" and .resolved == $version and
        (.contentHash | type == "string" and length > 0)' "$lock" >/dev/null
jq -e --arg package Pomelo.EntityFrameworkCore.MySql \
    --arg version "$mysql_ef_version" \
    '.dependencies["net10.0"][$package] |
        .type == "Direct" and .resolved == $version and
        (.contentHash | type == "string" and length > 0)' "$lock" >/dev/null
deps=/var/www/aspnetcore/TurnkeyExampleApp.deps.json
jq -e --arg package "Microsoft.EntityFrameworkCore.Relational/$ef_version" \
    '.libraries[$package]' "$deps" >/dev/null
jq -e --arg package "Pomelo.EntityFrameworkCore.MySql/$mysql_ef_version" \
    '.libraries[$package]' "$deps" >/dev/null
test "$(stat -c '%U:%G:%a' /var/www/aspnetcore/appsettings.json)" = \
    'root:www-data:640'

redirect=$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}|%{redirect_url}' http://127.0.0.1/)
[[ $redirect == 302\|https://*/ ]]
curl --insecure --fail --silent --show-error https://127.0.0.1/ >"$page"
grep -Fq 'Welcome to Turnkey ASP.NET Core' "$page"
curl --insecure --fail --silent --show-error https://127.0.0.1/DBExample >"$page"
grep -Fq 'Data here is loaded from MySQL' "$page"
grep -Fq 'First item' "$page"
grep -Fq 'Last item' "$page"
MYSQL_PWD=$db_password mariadb --user=root --batch --skip-column-names \
    example --execute='SELECT COUNT(*) FROM ExampleThing' | grep -Fxq 3

systemctl restart aspnetcore.service
systemctl --quiet is-active aspnetcore.service
curl --insecure --retry 10 --retry-connrefused --retry-delay 1 \
    --fail --silent --show-error https://127.0.0.1/DBExample >"$page"
grep -Fq 'First item' "$page"

aspnetcore-update --check >"$update"
sdk_candidate=$(sed -n 's/^sdk_candidate=//p' "$update")
runtime_candidate=$(sed -n 's/^runtime_candidate=//p' "$update")
ef_candidate=$(sed -n 's/^ef_candidate=//p' "$update")
provider_candidate=$(sed -n 's/^provider_candidate=//p' "$update")
ef_asset=$(sed -n 's/^ef_asset=//p' "$update")
provider_asset=$(sed -n 's/^provider_asset=//p' "$update")
status=$(sed -n 's/^status=//p' "$update")
[[ $sdk_candidate == 10.0.* ]]
[[ $runtime_candidate == 10.0.* ]]
[[ $ef_candidate =~ ^9\.[0-9]+\.[0-9]+$ ]]
[[ $provider_candidate =~ ^9\.[0-9]+\.[0-9]+$ ]]
grep -Fxq 'channel=microsoft-debian-13-dotnet-10-and-stable-ef9-pomelo9' "$update"
curl --fail --silent --show-error --head "$ef_asset" >/dev/null
curl --fail --silent --show-error --head "$provider_asset" >/dev/null

cat >"$result" <<EOF
package_source=Microsoft Debian 13 feed for .NET $dotnet_channel; NuGet dependencies locked by packages.lock.json
installed_version=.NET SDK $sdk_version; EF Core $ef_version; Pomelo provider $mysql_ef_version
runtime_checks=normal init; Nginx HTTP redirect and HTTPS proxy; ASP.NET sample; EF Core MariaDB page and direct readback; systemd restart persistence
updater_command=aspnetcore-update --check
updater_result=$status; SDK candidate=$sdk_candidate; runtime candidate=$runtime_candidate; EF candidate=$ef_candidate; provider candidate=$provider_candidate
updater_channel=Microsoft Debian 13 .NET 10 LTS and stable NuGet EF 9/Pomelo 9
integrity_evidence=Microsoft key $microsoft_key_fingerprint; NuGet direct-package content hashes; lock SHA-256 $lock_sha256
EOF
